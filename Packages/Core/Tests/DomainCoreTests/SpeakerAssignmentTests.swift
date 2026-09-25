//  SpeakerAssignmentTests — MEE-420 часть 5, план MEE-410, группы Д и Е (К15-К20):
//  `AppFacadeImpl.assignSpeaker`/`clearSpeaker`/`createPersonAndAssign`/`forgetVoiceProfile`
//  на прямых фейках портов, не `FakeAppFacade` (план MEE-410, §0). К50-К52 (дельта Щ перечня
//  MEE-401) — в `SpeakerAssignmentTests+DeltaShch.swift`, тот же класс, разведено по объёму
//  (`file_length`/`type_body_length`); `Fixture`/`makeFixture()`/`resultWithOneUpdate()`/
//  `segmentRows()` не `private` специально ради того файла.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class SpeakerAssignmentTests: XCTestCase {

    struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let attribution: FakeAttributionPort
        let transcriptId: UUID
        /// Два сегмента — К51 требует минимум два в кластере вызова.
        let clusterASegmentIds: [Int64]
        let clusterBSegmentIds: [Int64]
    }

    /// По одному слову на сегмент, в его собственных границах — К15/К16 ссылаются на
    /// `wordIndex` 0 через `TextCorrection`, а `applyTextCorrections` проверяет его в
    /// границах `words` самого сегмента. Канал всегда `.system` — только он допускает
    /// непустой `speakerCluster` при непустом тексте (инв. 6); `.mic`, напротив, требует
    /// `nil` (инв. 5).
    private func makeSegment(startMs: Int, endMs: Int, cluster: Int, text: String) throws -> Transcript.Segment {
        let word = try Transcript.Word(startMs: startMs, endMs: endMs, text: "слово", confidence: nil, original: nil)
        return try Transcript.Segment(
            startMs: startMs, endMs: endMs, channel: .system, speakerCluster: cluster,
            text: text, textOriginal: nil, textConfidence: nil, words: [word]
        )
    }

    /// Три сегмента: два в кластере 0 (К51 требует минимум два в кластере вызова), один в
    /// кластере 1.
    func makeFixture() async throws -> Fixture {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let segmentA1 = try makeSegment(startMs: 0, endMs: 800, cluster: 0, text: "слова кластера А1")
        let segmentA2 = try makeSegment(startMs: 800, endMs: 1600, cluster: 0, text: "слова кластера А2")
        let segmentB1 = try makeSegment(startMs: 1600, endMs: 2400, cluster: 1, text: "слова кластера Б1")
        // Инв. 9: каждый speakerCluster сегмента обязан присутствовать среди speakers.
        // embeddingModelVersion непуст хотя бы у одного — иначе AttributionSupport.buildInput
        // считает вход испорченным (§7 «embeddingModelVersion»); инв. 10 требует embedding
        // и embeddingModelVersion только парой, поэтому оба заданы вместе.
        let speakerA = try Transcript.Speaker(
            cluster: 0, embedding: [0.1, 0.2], embeddingModelVersion: "v1", totalMs: 1_600
        )
        let speakerB = try Transcript.Speaker(
            cluster: 1, embedding: [0.3, 0.4], embeddingModelVersion: "v1", totalMs: 800
        )
        let transcript = try Transcript(
            recordingId: recordingId, language: "ru", engine: "engine", modelVersion: "1.0",
            createdAt: Date(timeIntervalSince1970: 0), segments: [segmentA1, segmentA2, segmentB1],
            speakers: [speakerA, speakerB]
        )
        let header = try await repositories.transcripts.save(transcript)
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        let clusterASegmentIds = rows.filter { $0.segment.speakerCluster == 0 }.map(\.id)
        let clusterBSegmentIds = rows.filter { $0.segment.speakerCluster == 1 }.map(\.id)
        let attribution = FakeAttributionPort()
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: attribution,
            settings: repositories.settings,
            clock: { Date() }
        )
        return Fixture(
            facade: facade, repositories: repositories, attribution: attribution,
            transcriptId: header.id, clusterASegmentIds: clusterASegmentIds, clusterBSegmentIds: clusterBSegmentIds
        )
    }

    private func emptyResult(transcriptId: UUID) -> AttributionResult {
        AttributionResult(
            transcriptId: transcriptId, assignments: [], segmentUpdates: [], textCorrections: [], profileUpdates: []
        )
    }

    /// К50: РП явно требует непустой `segmentUpdates` — реализация «всегда пустой список»
    /// не должна проходить тест только потому, что результат тоже пуст.
    func resultWithOneUpdate(transcriptId: UUID, segmentId: Int64) -> AttributionResult {
        AttributionResult(
            transcriptId: transcriptId, assignments: [],
            segmentUpdates: [SegmentAttributionUpdate(
                segmentId: segmentId, personId: UUID(), speakerConfidence: 0.9, attributionSource: .user
            )],
            textCorrections: [], profileUpdates: []
        )
    }

    func segmentRows(_ fixture: Fixture) async throws -> [SegmentRow] {
        try await fixture.repositories.transcripts.segments(transcriptId: fixture.transcriptId)
    }

    // MARK: - К15 (инв. 13, 14): confirm вызван, результат применён тремя вызовами

    func test_k15_assignSpeakerAppliesAttributionResultViaThreeCalls() async throws {
        let fixture = try await makeFixture()
        let personId = UUID()
        let segmentId = fixture.clusterASegmentIds[0]
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: fixture.transcriptId,
            assignments: [],
            segmentUpdates: [SegmentAttributionUpdate(
                segmentId: segmentId, personId: personId, speakerConfidence: 0.9, attributionSource: .user
            )],
            textCorrections: [TextCorrection(
                segmentId: segmentId, wordIndex: 0, original: "х", replacement: "у",
                personId: personId, similarity: 1.0
            )],
            profileUpdates: [SpeakerProfileUpdate(
                personId: personId, embedding: [0.1], modelVersion: "v1", sampleCount: 1
            )]
        )

        try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: personId)

        XCTAssertEqual(fixture.attribution.confirmCallCount, 1)
        XCTAssertEqual(fixture.attribution.lastConfirmedTranscriptId, fixture.transcriptId)
        XCTAssertEqual(fixture.attribution.lastConfirmedCluster, 0)
        XCTAssertEqual(fixture.attribution.lastConfirmedPersonId, personId)

        let log = fixture.repositories.log
        XCTAssertEqual(log.count(port: "TranscriptRepository", method: "updateAttribution(_:)"), 1)
        XCTAssertEqual(log.count(port: "SpeakerProfileRepository", method: "upsert(_:)"), 1)
        XCTAssertEqual(
            log.count(port: "TranscriptRepository", method: "applyTextCorrections(segmentId:text:corrections:)"), 1
        )
    }

    // MARK: - К16: пометка is_user_edited идёт после всех трёх вызовов применения

    func test_k16_markedAfterAllThreeApplicationCallsNotJustLast() async throws {
        let fixture = try await makeFixture()
        let personId = UUID()
        let segmentId = fixture.clusterASegmentIds[0]
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: fixture.transcriptId,
            assignments: [],
            segmentUpdates: [SegmentAttributionUpdate(
                segmentId: segmentId, personId: personId, speakerConfidence: 0.9, attributionSource: .user
            )],
            textCorrections: [TextCorrection(
                segmentId: segmentId, wordIndex: 0, original: "х", replacement: "у",
                personId: personId, similarity: 1.0
            )],
            profileUpdates: [SpeakerProfileUpdate(
                personId: personId, embedding: [0.1], modelVersion: "v1", sampleCount: 1
            )]
        )

        try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: personId)

        let log = fixture.repositories.log
        let markSignature = "TranscriptRepository.markSegmentsUserEdited(segmentIds:)"
        XCTAssertTrue(log.happened("TranscriptRepository.updateAttribution(_:)", before: markSignature))
        XCTAssertTrue(log.happened("SpeakerProfileRepository.upsert(_:)", before: markSignature))
        let applyTextCorrectionsSignature = "TranscriptRepository.applyTextCorrections(segmentId:text:corrections:)"
        XCTAssertTrue(log.happened(applyTextCorrectionsSignature, before: markSignature))
    }

    // MARK: - К17: reject не несёт personId — SpeakerProfileRepository.upsert не вызывается без profileUpdates

    func test_k17_clearSpeakerSkipsProfileUpsertWithoutProfileUpdates() async throws {
        let fixture = try await makeFixture()
        // Непустой segmentUpdates — «upsert не вызывается» обязано держаться при реальном
        // применении результата, не только когда применять вообще нечего.
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: fixture.transcriptId, assignments: [],
            segmentUpdates: [SegmentAttributionUpdate(
                segmentId: fixture.clusterASegmentIds[0], personId: nil, speakerConfidence: nil,
                attributionSource: .user
            )],
            textCorrections: [], profileUpdates: []
        )

        try await fixture.facade.clearSpeaker(transcriptId: fixture.transcriptId, cluster: 0)

        XCTAssertEqual(fixture.attribution.rejectCallCount, 1)
        XCTAssertEqual(fixture.attribution.lastRejectedCluster, 0)
        XCTAssertEqual(
            fixture.repositories.log.count(port: "TranscriptRepository", method: "updateAttribution(_:)"), 1,
            "сегментные обновления применяются"
        )
        XCTAssertEqual(fixture.repositories.log.count(port: "SpeakerProfileRepository", method: "upsert(_:)"), 0)
    }

    // MARK: - К18: все шесть случаев AttributionError сводятся к .underlying с кодом из словаря §3.1

    func test_k18_attributionPortErrorSurfacesAsUnderlying() async throws {
        let cases: [(error: AttributionError, code: String)] = [
            (.unknownTranscript(UUID()), "attribution.unknownTranscript"),
            (.unknownCluster(99), "attribution.unknownCluster"),
            (.unknownPerson(UUID()), "attribution.unknownPerson"),
            (.embeddingModelMismatch(expected: "v1", actual: "v2"), "attribution.embeddingModelMismatch"),
            (.segmentIdsMismatch(expected: 2, actual: 3), "attribution.segmentIdsMismatch"),
            (.voiceProfilesDisabled, "attribution.voiceProfilesDisabled")
        ]
        for testCase in cases {
            let fixture = try await makeFixture()
            fixture.attribution.forcedError = testCase.error

            do {
                try await fixture.facade.assignSpeaker(
                    transcriptId: fixture.transcriptId, cluster: 0, personId: UUID()
                )
                XCTFail("\(testCase.error): ожидался AppFacadeError.underlying")
            } catch AppFacadeError.underlying(let view) {
                XCTAssertEqual(view.code, testCase.code, "\(testCase.error)")
            }
        }
    }

    // MARK: - К19: email привязан там, где задан; та же последовательность, что К15

    func test_k19_createPersonAndAssignAttachesEmailThenSameSequence() async throws {
        let fixture = try await makeFixture()
        fixture.attribution.forcedResult = emptyResult(transcriptId: fixture.transcriptId)

        let personId = try await fixture.facade.createPersonAndAssign(
            transcriptId: fixture.transcriptId, cluster: 0, displayName: "Иван Иванов", email: "ivan@example.com"
        )

        let person = try await fixture.repositories.persons.person(id: personId)
        XCTAssertEqual(person?.displayName, "Иван Иванов")
        XCTAssertEqual(person?.emails, ["ivan@example.com"])
        XCTAssertEqual(fixture.attribution.confirmCallCount, 1)
        XCTAssertEqual(fixture.attribution.lastConfirmedPersonId, personId)
        XCTAssertEqual(fixture.attribution.lastConfirmedCluster, 0)
    }

    /// К19: `email == nil` — `upsert(displayName:emails:)` получает пустой список, не `[nil]`.
    func test_k19_createPersonAndAssignWithNilEmail() async throws {
        let fixture = try await makeFixture()
        fixture.attribution.forcedResult = emptyResult(transcriptId: fixture.transcriptId)

        let personId = try await fixture.facade.createPersonAndAssign(
            transcriptId: fixture.transcriptId, cluster: 0, displayName: "Пётр Петров", email: nil
        )

        let person = try await fixture.repositories.persons.person(id: personId)
        XCTAssertEqual(person?.displayName, "Пётр Петров")
        XCTAssertEqual(person?.emails, [])
    }

    // MARK: - К20: forgetVoiceProfile удаляет профиль; AttributionPort не вызывается вовсе

    func test_k20_forgetVoiceProfileCallsDeleteOnceNoAttributionPort() async throws {
        let fixture = try await makeFixture()
        let personId = UUID()

        try await fixture.facade.forgetVoiceProfile(personId: personId)

        XCTAssertEqual(
            fixture.repositories.log.count(port: "SpeakerProfileRepository", method: "delete(personId:)"), 1
        )
        XCTAssertEqual(fixture.attribution.attributeCallCount, 0)
        XCTAssertEqual(fixture.attribution.confirmCallCount, 0)
        XCTAssertEqual(fixture.attribution.rejectCallCount, 0)
    }

    // MARK: - Приёмка РП 07:30 UTC: voiceProfilesEnabled читается из settings(), не литералом

    /// До слияния MEE-425 (группа Ж) `settings()` бросал `notImplemented`, и `voiceProfilesEnabled`
    /// был литералом `false`. Теперь `settings()` реализован (`AppFacadeImpl+Settings.swift`) —
    /// значение обязано отражать то, что лежит в `SettingsRepository`, а не подставленный литерал.
    func test_voiceProfilesEnabledIsReadFromSettingsNotHardcoded() async throws {
        let fixture = try await makeFixture()
        try await fixture.repositories.settings.setValue(
            try DomainJSON.encode(true), forKey: "voiceProfilesEnabled"
        )
        fixture.attribution.forcedResult = emptyResult(transcriptId: fixture.transcriptId)

        try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: UUID())

        let input = try XCTUnwrap(fixture.attribution.lastConfirmedInput)
        XCTAssertTrue(input.voiceProfilesEnabled, "ожидалось значение из SettingsRepository, не false-литерал")
    }

    /// Отказ `settings()` (инв. 28: строка есть, но не читается) пробрасывается наружу как
    /// есть — не заворачивается повторно в `app.internalError`.
    func test_settingsFailurePropagatesWithoutDoubleWrapping() async throws {
        let fixture = try await makeFixture()
        try await fixture.repositories.settings.setValue(Data("не JSON".utf8), forKey: "voiceProfilesEnabled")

        do {
            try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: UUID())
            XCTFail("ожидался AppFacadeError.settingsUnreadable")
        } catch AppFacadeError.settingsUnreadable(let key) {
            XCTAssertEqual(key, "voiceProfilesEnabled")
        }
    }

}
