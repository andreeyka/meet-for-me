//  SpeakerAssignmentTests — добор К17 и К19 по сверке покрытия MEE-401 (`484179e8`), MEE-448.
//  Разведено из `SpeakerAssignmentTests.swift` по объёму (`type_body_length`), не по смыслу —
//  тот же класс, `makeFixture()`/`segmentRows()` оттуда.
//
//  Что добирается. Существующие К17/К19 проверяли только часть ответа: у `clearSpeaker` —
//  `reject`, `updateAttribution` = 1 и `upsert` = 0, без `textCorrections`, порядка и пометки;
//  у `createPersonAndAssign` — человека и `confirm`, а фейк порта отвечал пустым результатом,
//  так что «та же последовательность, что К15-К16» не наблюдалась вовсе.
//
//  `ScriptedAttributionPort` — локальная заглушка порта, а не `FakeAttributionPort`: ей нужно
//  (а) писать свой вызов в тот же `PortCallLog`, что и репозитории, — иначе «порт → применение»
//  несравнимо; (б) строить результат из `personId`, пришедшего в `confirm`, — у
//  `createPersonAndAssign` он заранее тесту не известен.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

extension SpeakerAssignmentTests {

    private static let updateAttribution = "TranscriptRepository.updateAttribution(_:)"
    private static let applyTextCorrections = "TranscriptRepository.applyTextCorrections(segmentId:text:corrections:)"
    private static let markUserEdited = "TranscriptRepository.markSegmentsUserEdited(segmentIds:)"
    private static let profileUpsert = "SpeakerProfileRepository.upsert(_:)"

    /// Фасад поверх репозиториев `makeFixture()`, но с `ScriptedAttributionPort` вместо
    /// `FakeAttributionPort`. Фасад самой фикстуры в этих тестах не вызывается.
    private func makeScriptedFacade(
        _ fixture: Fixture, port: ScriptedAttributionPort
    ) -> AppFacadeImpl {
        let repositories = fixture.repositories
        return AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: port,
            settings: repositories.settings,
            connectors: repositories.connectors,
            clock: { Date() }
        )
    }

    /// Правка слова 0 сегмента `segmentId`: в фикстуре у каждого сегмента одно слово
    /// «слово», поэтому применённая правка видна прямо в тексте строки.
    private static func correction(segmentId: Int64, personId: UUID) -> TextCorrection {
        TextCorrection(
            segmentId: segmentId, wordIndex: 0, original: "слово", replacement: "исправлено",
            personId: personId, similarity: 1.0
        )
    }

    // MARK: - К17: clearSpeaker — порт → применение (segmentUpdates + textCorrections) → пометка

    /// Вход К17 дословно: `reject` отвечает результатом без `profileUpdates`, но с
    /// `segmentUpdates`/`textCorrections`. Ответ: та же последовательность, что К15-К16, и
    /// `upsert` — 0. Различающий вектор К16 здесь тоже работает: пометка раньше
    /// `applyTextCorrections` дала бы строку, которую фейк репозитория (инв. 32 C-010) молча
    /// пропускает, и текст остался бы «слово».
    func test_k17_clearSpeakerAppliesSegmentUpdatesAndTextCorrectionsThenMarks() async throws {
        let fixture = try await makeFixture()
        let segmentId = fixture.clusterASegmentIds[0]
        let log = fixture.repositories.log
        let port = ScriptedAttributionPort(log: log) { transcriptId, _ in
            AttributionResult(
                transcriptId: transcriptId, assignments: [],
                segmentUpdates: [SegmentAttributionUpdate(
                    segmentId: segmentId, personId: nil, speakerConfidence: nil, attributionSource: .user
                )],
                textCorrections: [SpeakerAssignmentTests.correction(segmentId: segmentId, personId: UUID())],
                profileUpdates: []
            )
        }
        let facade = makeScriptedFacade(fixture, port: port)

        try await facade.clearSpeaker(transcriptId: fixture.transcriptId, cluster: 0)

        XCTAssertEqual(port.rejectCallCount, 1)
        XCTAssertEqual(port.confirmCallCount, 0)
        XCTAssertEqual(log.count(port: "TranscriptRepository", method: "updateAttribution(_:)"), 1)
        XCTAssertEqual(
            log.count(port: "TranscriptRepository", method: "applyTextCorrections(segmentId:text:corrections:)"), 1
        )
        XCTAssertEqual(
            log.count(port: "SpeakerProfileRepository", method: "upsert(_:)"), 0, "reject профиль не трогает"
        )

        let reject = ScriptedAttributionPort.rejectSignature
        XCTAssertTrue(log.happened(reject, before: Self.updateAttribution), "порт → применение")
        XCTAssertTrue(log.happened(reject, before: Self.applyTextCorrections), "порт → применение")
        XCTAssertTrue(log.happened(Self.updateAttribution, before: Self.markUserEdited), "применение → пометка")
        XCTAssertTrue(log.happened(Self.applyTextCorrections, before: Self.markUserEdited), "применение → пометка")

        let rows = try await segmentRows(fixture)
        let corrected = try XCTUnwrap(rows.first { $0.id == segmentId })
        XCTAssertEqual(corrected.segment.text, "исправлено", "textCorrections применены, не пропущены")
        XCTAssertNil(corrected.personId, "segmentUpdates применены: кластер снят")
        for id in fixture.clusterASegmentIds {
            XCTAssertEqual(rows.first { $0.id == id }?.isUserEdited, true, "сегмент \(id) кластера 0 помечен")
        }
        for id in fixture.clusterBSegmentIds {
            XCTAssertEqual(rows.first { $0.id == id }?.isUserEdited, false, "чужой кластер не помечен")
        }
    }

    // MARK: - К19: createPersonAndAssign — человек → confirm → применение → пометка

    /// Ответ К19: «далее выполняется та же последовательность, что `assignSpeaker`
    /// (К15-К16)». Порт отвечает НЕпустым результатом (все три коллекции), построенным из
    /// того `personId`, что фасад передал в `confirm`, — так наблюдаемо, что применён
    /// именно результат для только что созданного человека.
    func test_k19_createPersonAndAssignAppliesNonEmptyResultThenMarks() async throws {
        let fixture = try await makeFixture()
        let segmentId = fixture.clusterASegmentIds[0]
        let log = fixture.repositories.log
        let port = ScriptedAttributionPort(log: log) { transcriptId, personId in
            let personId = personId ?? UUID()
            return AttributionResult(
                transcriptId: transcriptId, assignments: [],
                segmentUpdates: [SegmentAttributionUpdate(
                    segmentId: segmentId, personId: personId, speakerConfidence: 0.9, attributionSource: .user
                )],
                textCorrections: [SpeakerAssignmentTests.correction(segmentId: segmentId, personId: personId)],
                profileUpdates: [SpeakerProfileUpdate(
                    personId: personId, embedding: [0.1, 0.2], modelVersion: "v1", sampleCount: 1
                )]
            )
        }
        let facade = makeScriptedFacade(fixture, port: port)

        let personId = try await facade.createPersonAndAssign(
            transcriptId: fixture.transcriptId, cluster: 0, displayName: "Мария Сидорова", email: "maria@example.com"
        )

        XCTAssertEqual(port.confirmCallCount, 1)
        XCTAssertEqual(port.lastConfirmedPersonId, personId)
        let person = try await fixture.repositories.persons.person(id: personId)
        XCTAssertEqual(person?.emails, ["maria@example.com"])

        XCTAssertEqual(log.count(port: "TranscriptRepository", method: "updateAttribution(_:)"), 1)
        XCTAssertEqual(log.count(port: "SpeakerProfileRepository", method: "upsert(_:)"), 1)
        XCTAssertEqual(
            log.count(port: "TranscriptRepository", method: "applyTextCorrections(segmentId:text:corrections:)"), 1
        )
        let confirm = ScriptedAttributionPort.confirmSignature
        XCTAssertTrue(log.happened("PersonRepository.upsert(displayName:emails:)", before: confirm), "человек → порт")
        for application in [Self.updateAttribution, Self.profileUpsert, Self.applyTextCorrections] {
            XCTAssertTrue(log.happened(confirm, before: application), "порт → \(application)")
            XCTAssertTrue(log.happened(application, before: Self.markUserEdited), "\(application) → пометка")
        }

        let rows = try await segmentRows(fixture)
        let applied = try XCTUnwrap(rows.first { $0.id == segmentId })
        XCTAssertEqual(applied.personId, personId, "segmentUpdates применены с personId нового человека")
        XCTAssertEqual(applied.segment.text, "исправлено", "textCorrections применены, не пропущены")
        let profile = try await fixture.repositories.speakerProfiles.profile(personId: personId, modelVersion: "v1")
        XCTAssertNotNil(profile, "profileUpdates применены")
        for id in fixture.clusterASegmentIds {
            XCTAssertEqual(rows.first { $0.id == id }?.isUserEdited, true, "сегмент \(id) кластера 0 помечен")
        }
        for id in fixture.clusterBSegmentIds {
            XCTAssertEqual(rows.first { $0.id == id }?.isUserEdited, false, "чужой кластер не помечен")
        }
    }
}

/// Заглушка `AttributionPort` для К17/К19 — см. шапку файла. `attribute` фасадом не
/// вызывается ни на одном из этих путей; вызов его — провал теста, а не молчаливый ответ.
final class ScriptedAttributionPort: AttributionPort, @unchecked Sendable {
    static let confirmSignature = "AttributionPort.confirm(transcriptId:cluster:personId:input:)"
    static let rejectSignature = "AttributionPort.reject(transcriptId:cluster:input:)"

    private let lock = NSLock()
    private let log: PortCallLog
    /// Ответ порта: `personId` — пришедший в `confirm`, `nil` — для `reject`.
    private let makeResult: @Sendable (UUID, UUID?) -> AttributionResult
    private var confirmCalls = 0
    private var rejectCalls = 0
    private var confirmedPersonId: UUID?

    init(log: PortCallLog, makeResult: @escaping @Sendable (UUID, UUID?) -> AttributionResult) {
        self.log = log
        self.makeResult = makeResult
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var confirmCallCount: Int { locked { confirmCalls } }
    var rejectCallCount: Int { locked { rejectCalls } }
    var lastConfirmedPersonId: UUID? { locked { confirmedPersonId } }

    func attribute(_ input: AttributionInput, thresholds: AttributionThresholds) async throws -> AttributionResult {
        XCTFail("attribute не должен вызываться фасадом на путях clearSpeaker/createPersonAndAssign")
        return makeResult(input.transcriptId, nil)
    }

    func confirm(
        transcriptId: UUID, cluster: Int, personId: UUID, input: AttributionInput
    ) async throws -> AttributionResult {
        log.record(port: "AttributionPort", method: "confirm(transcriptId:cluster:personId:input:)")
        locked {
            confirmCalls += 1
            confirmedPersonId = personId
        }
        return makeResult(transcriptId, personId)
    }

    func reject(transcriptId: UUID, cluster: Int, input: AttributionInput) async throws -> AttributionResult {
        log.record(port: "AttributionPort", method: "reject(transcriptId:cluster:input:)")
        locked { rejectCalls += 1 }
        return makeResult(transcriptId, nil)
    }
}
