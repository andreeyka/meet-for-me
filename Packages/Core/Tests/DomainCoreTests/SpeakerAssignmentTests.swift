//  SpeakerAssignmentTests — MEE-420 часть 5, план MEE-410, группы Д и Е (К15-К20) +
//  К50-К52 (дельта Щ перечня MEE-401): `AppFacadeImpl.assignSpeaker`/`clearSpeaker`/
//  `createPersonAndAssign`/`forgetVoiceProfile` на прямых фейках портов, не `FakeAppFacade`
//  (план MEE-410, §0).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class SpeakerAssignmentTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let attribution: FakeAttributionPort
        let transcriptId: UUID
        let clusterASegmentIds: [Int64]
        let clusterBSegmentIds: [Int64]
    }

    /// Два сегмента системного канала, по одному на кластер (0 и 1) — `.system` с непустым
    /// текстом требует `speakerCluster != nil` (инв. 6); `.mic`, напротив, требует `nil`
    /// (инв. 5), поэтому кластерам здесь годится только системный канал.
    private func makeFixture() async throws -> Fixture {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        // По одному слову на сегмент — К15/К16 ссылаются на wordIndex 0 через TextCorrection,
        // а applyTextCorrections проверяет его в границах words самого сегмента.
        let wordA = try Transcript.Word(startMs: 0, endMs: 800, text: "слово", confidence: nil, original: nil)
        let wordB = try Transcript.Word(startMs: 800, endMs: 1600, text: "слово", confidence: nil, original: nil)
        let segmentA = try Transcript.Segment(
            startMs: 0, endMs: 800, channel: .system, speakerCluster: 0,
            text: "слова кластера А", textOriginal: nil, textConfidence: nil, words: [wordA]
        )
        let segmentB = try Transcript.Segment(
            startMs: 800, endMs: 1600, channel: .system, speakerCluster: 1,
            text: "слова кластера Б", textOriginal: nil, textConfidence: nil, words: [wordB]
        )
        // Инв. 9: каждый speakerCluster сегмента обязан присутствовать среди speakers.
        // embeddingModelVersion непуст хотя бы у одного — иначе AttributionSupport.buildInput
        // считает вход испорченным (§7 «embeddingModelVersion»); инв. 10 требует embedding
        // и embeddingModelVersion только парой, поэтому оба заданы вместе.
        let speakerA = try Transcript.Speaker(
            cluster: 0, embedding: [0.1, 0.2], embeddingModelVersion: "v1", totalMs: 800
        )
        let speakerB = try Transcript.Speaker(
            cluster: 1, embedding: [0.3, 0.4], embeddingModelVersion: "v1", totalMs: 800
        )
        let transcript = try Transcript(
            recordingId: recordingId, language: "ru", engine: "engine", modelVersion: "1.0",
            createdAt: Date(timeIntervalSince1970: 0), segments: [segmentA, segmentB],
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

    private func segmentRows(_ fixture: Fixture) async throws -> [SegmentRow] {
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
        fixture.attribution.forcedResult = emptyResult(transcriptId: fixture.transcriptId)

        try await fixture.facade.clearSpeaker(transcriptId: fixture.transcriptId, cluster: 0)

        XCTAssertEqual(fixture.attribution.rejectCallCount, 1)
        XCTAssertEqual(fixture.attribution.lastRejectedCluster, 0)
        XCTAssertEqual(fixture.repositories.log.count(port: "SpeakerProfileRepository", method: "upsert(_:)"), 0)
    }

    // MARK: - К18: AttributionError сводится к .underlying с кодом из словаря §3.1

    func test_k18_attributionPortErrorSurfacesAsUnderlying() async throws {
        let fixture = try await makeFixture()
        fixture.attribution.forcedError = .unknownCluster(99)

        do {
            try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: UUID())
            XCTFail("ожидался AppFacadeError.underlying")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "attribution.unknownCluster")
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

    // MARK: - К50 (дельта Щ): сегменты назначаемого кластера исключены из userEditedSegmentIds

    func test_k50_userEditedSegmentIdsExcludesTargetCluster() async throws {
        let fixture = try await makeFixture()
        let segmentId = fixture.clusterASegmentIds[0]
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: segmentId, text: "уже правлено", isUserEdited: true
        )
        fixture.attribution.forcedResult = emptyResult(transcriptId: fixture.transcriptId)

        try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: UUID())

        let input = try XCTUnwrap(fixture.attribution.lastConfirmedInput)
        XCTAssertFalse(
            input.userEditedSegmentIds.contains(segmentId),
            "сегмент назначаемого кластера обязан быть исключён, даже уже помеченный"
        )
    }

    // MARK: - К51 (дельта Щ): помечен весь кластер, ни один сегмент другого кластера

    func test_k51_markingCoversOnlyTargetClusterNotOther() async throws {
        let fixture = try await makeFixture()
        fixture.attribution.forcedResult = emptyResult(transcriptId: fixture.transcriptId)

        try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: UUID())

        let rows = try await segmentRows(fixture)
        for segmentId in fixture.clusterASegmentIds {
            let row = try XCTUnwrap(rows.first { $0.id == segmentId })
            XCTAssertTrue(row.isUserEdited, "сегмент \(segmentId) кластера 0 обязан быть помечен")
        }
        for segmentId in fixture.clusterBSegmentIds {
            let row = try XCTUnwrap(rows.first { $0.id == segmentId })
            XCTAssertFalse(row.isUserEdited, "сегмент \(segmentId) чужого кластера 1 не должен быть помечен")
        }
    }

    // MARK: - К52 (дельта Щ, C-010 инв. 17): повторное ручное назначение того же кластера не теряется

    func test_k52_reassigningAlreadyEditedClusterStillAppliesUpdate() async throws {
        let fixture = try await makeFixture()
        let segmentId = fixture.clusterASegmentIds[0]
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: segmentId, text: "первая правка", isUserEdited: true
        )
        fixture.attribution.appliesInvariant8 = true
        let personId = UUID()
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: fixture.transcriptId,
            assignments: [],
            segmentUpdates: [SegmentAttributionUpdate(
                segmentId: segmentId, personId: personId, speakerConfidence: 0.95, attributionSource: .user
            )],
            textCorrections: [], profileUpdates: []
        )

        try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: personId)

        // Если бы К50 не исключил сегмент из userEditedSegmentIds, честный порт (appliesInvariant8)
        // отфильтровал бы это обновление сам, и updateAttribution не увидел бы ни одной строки.
        XCTAssertEqual(
            fixture.repositories.log.count(port: "TranscriptRepository", method: "updateAttribution(_:)"), 1
        )
        let rows = try await segmentRows(fixture)
        let row = try XCTUnwrap(rows.first { $0.id == segmentId })
        XCTAssertEqual(row.personId, personId)
        XCTAssertTrue(row.isUserEdited)
    }
}
