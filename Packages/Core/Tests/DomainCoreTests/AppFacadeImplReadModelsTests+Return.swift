//  AppFacadeImplReadModelsTests — возврат приёмки `bf060b8` (MEE-420 ч.2, PR #145). Разведено
//  из `AppFacadeImplReadModelsTests.swift` по объёму (`type_body_length`/`file_length`), не по
//  смыслу — тот же класс, `makeFacade()`/`epoch`/`event`/`segment`/`manifest` оттуда не `private`
//  специально ради этого файла.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

extension AppFacadeImplReadModelsTests {

    // MARK: - К6 (инв. 5): segments по startMs, speakers по убыванию totalMs

    /// `Transcript.init` сам требует `segments` уже по неубыванию `startMs` (инв. 3), а
    /// `InMemoryTranscriptRepository.segments(transcriptId:)` отдаёт строки в порядке
    /// вставки — на этой паре само по себе прохождение теста тавтологично (проверка на
    /// уже отсортированном входе). `ReversedOrderTranscriptRepository` подменяет только
    /// чтение сегментов на заведомо перепутанный порядок, оставляя запись и остальные
    /// методы делегированными настоящему фейку, — так наблюдаемо проверено, что
    /// `AppFacadeImpl` сортирует сам, а не полагается на порядок хранилища.
    func test_k06_transcriptViewSortsSegmentsAscendingAndSpeakersDescending() async throws {
        let fixture = makeFacade(transcripts: { ReversedOrderTranscriptRepository(inner: $0) })
        let facade = fixture.facade
        let repositories = fixture.repositories
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let speakers = try [
            Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 1_000),
            Transcript.Speaker(cluster: 1, embedding: nil, embeddingModelVersion: nil, totalMs: 5_000)
        ]
        let segments = try [
            segment(startMs: 0, endMs: 1_000, cluster: 0, text: "первый по времени"),
            segment(startMs: 2_000, endMs: 3_000, cluster: 1, text: "второй по времени")
        ]
        let header = try await repositories.transcripts.save(
            try Transcript(
                recordingId: recordingId, language: "ru", engine: "e", modelVersion: "1",
                createdAt: epoch, segments: segments, speakers: speakers
            )
        )

        let view = try await facade.transcript(id: header.id)

        let unwrapped = try XCTUnwrap(view)
        XCTAssertEqual(unwrapped.segments.map(\.text), ["первый по времени", "второй по времени"])
        XCTAssertEqual(unwrapped.speakers.map(\.cluster), [1, 0], "по убыванию totalMs: 5000 раньше 1000")
    }

    // MARK: - К8, продолжение: isUncertain == false, confidence nil/на пороге

    /// Случай `false`/не-низкая-уверенность — confidence ровно на пороге не считается ниже
    /// него (`<`, не `<=`), и слово с `confidence == nil` не попадает в
    /// `lowConfidenceWordIndexes` вовсе (инв. 8 к нему не применяется — оговорено в
    /// `TranscriptNested.swift`).
    func test_k08_isUncertainFalseAndNilOrThresholdConfidenceExcludedFromLowConfidenceIndexes() async throws {
        let fixture = makeFacade()
        let facade = fixture.facade
        let repositories = fixture.repositories
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let thresholds = AttributionThresholds.slice1Defaults
        let atThresholdWord = try Transcript.Word(
            startMs: 0, endMs: 100, text: "порог", confidence: thresholds.textConfidenceMax, original: nil
        )
        let nilConfidenceWord = try Transcript.Word(
            startMs: 100, endMs: 200, text: "неизвестно", confidence: nil, original: nil
        )
        let lowWord = try Transcript.Word(
            startMs: 200, endMs: 300, text: "тихо", confidence: thresholds.textConfidenceMax - 0.01, original: nil
        )
        let speakers = try [Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 1_000)]
        let segments = try [
            Transcript.Segment(
                startMs: 0, endMs: 300, channel: .system, speakerCluster: 0,
                text: "порог неизвестно тихо", textOriginal: nil,
                // Инв. 8 не применяется, если хоть у одного слова confidence == nil —
                // textConfidence может быть любым допустимым (инв. 7), не минимумом по словам.
                textConfidence: 0.5, words: [atThresholdWord, nilConfidenceWord, lowWord]
            )
        ]
        let header = try await repositories.transcripts.save(
            try Transcript(
                recordingId: recordingId, language: "ru", engine: "e", modelVersion: "1",
                createdAt: epoch, segments: segments, speakers: speakers
            )
        )
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        let personId = try await repositories.persons.upsert(displayName: "Иван", emails: ["ivan@example.com"])
        try await repositories.transcripts.updateAttribution([
            SegmentAttributionUpdate(
                segmentId: rows[0].id, personId: personId,
                speakerConfidence: thresholds.confirmedConfidenceMin, attributionSource: .voiceProfile
            )
        ])

        let maybeView = try await facade.transcript(id: header.id)
        let view = try XCTUnwrap(maybeView)

        let speaker = try XCTUnwrap(view.speakers.first)
        XCTAssertFalse(speaker.isUncertain, "confidence == confirmedConfidenceMin — уже не ниже порога")
        let segmentView = try XCTUnwrap(view.segments.first)
        XCTAssertEqual(
            segmentView.lowConfidenceWordIndexes, [2],
            "слово 0 (ровно на пороге) и слово 1 (confidence nil) не считаются низкой уверенностью"
        )
    }

    // MARK: - Возврат приёмки `bf060b8`, п.1: transcript(id:) — заголовок именно запрошенного

    /// После retranscribe у одной записи несколько заголовков транскриптов. `transcript(id:)`
    /// обязан вернуть заголовок именно запрошенного `id`, а не первый попавшийся с тем же
    /// `recordingId` — старая реализация искала по `recordingId` и путала их местами.
    func test_transcriptByIdMatchesRequestedHeaderNotJustAnyOfSameRecording() async throws {
        let fixture = makeFacade()
        let facade = fixture.facade
        let repositories = fixture.repositories
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId

        let firstHeader = try await repositories.transcripts.save(
            try Transcript(
                recordingId: recordingId, language: "ru", engine: "engine-1", modelVersion: "1",
                createdAt: epoch, segments: [], speakers: []
            )
        )
        let secondHeader = try await repositories.transcripts.save(
            try Transcript(
                recordingId: recordingId, language: "ru", engine: "engine-2", modelVersion: "2",
                createdAt: epoch.addingTimeInterval(60), segments: [], speakers: []
            )
        )
        XCTAssertNotEqual(firstHeader.id, secondHeader.id, "оснастка: два разных транскрипта одной записи")

        let view = try await facade.transcript(id: secondHeader.id)

        let unwrapped = try XCTUnwrap(view)
        XCTAssertEqual(unwrapped.header.id, secondHeader.id)
        XCTAssertEqual(
            unwrapped.header.engine, "engine-2",
            "заголовок именно запрошенного транскрипта, не первого того же recordingId"
        )
    }

    // MARK: - Возврат приёмки `bf060b8`, п.2: инв. 19, §3.1 — постороннее исключение → app.internalError

    /// `catch let error as PermissionsError` — не единственный обработчик: что-то за пределами
    /// словаря §3.1 (здесь — заведомо посторонняя ошибка порта) обязано свестись к
    /// `.underlying(code: "app.internalError")`, а не уйти наружу как есть. Проверено на одной
    /// точке (`openPermissionSettings`) — приём (общий `catch` после типизированного) одинаков
    /// на всех девяти местах `+Reads.swift`/`AppFacadeImpl.swift`, отдельного теста на каждое
    /// это не даёт новой информации.
    func test_inv19_unexpectedPortErrorIsWrappedAsAppInternalError() async throws {
        let repositories = InMemoryRepositories()
        let permissions = FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: epoch)
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: ThrowingOpenSettingsPermissionsPort(inner: permissions),
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings
        )

        do {
            try await facade.openPermissionSettings(.microphone)
            XCTFail("ожидалась посторонняя ошибка, сведённая к app.internalError")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "app.internalError")
        }
    }
}

/// К6 (см. `test_k06_...`): делегирует всё `TranscriptRepository` внутреннему фейку, кроме
/// `segments(transcriptId:)`, который отдаёт строки в обратном порядке — так тест проверяет
/// сортировку `AppFacadeImpl`, а не порядок вставки фейка.
private final class ReversedOrderTranscriptRepository: TranscriptRepository, @unchecked Sendable {
    let inner: InMemoryTranscriptRepository

    init(inner: InMemoryTranscriptRepository) {
        self.inner = inner
    }

    func save(_ transcript: Transcript) async throws -> TranscriptHeader {
        try await inner.save(transcript)
    }

    func headers(recordingId: UUID) async throws -> [TranscriptHeader] {
        try await inner.headers(recordingId: recordingId)
    }

    func latest(recordingId: UUID) async throws -> TranscriptHeader? {
        try await inner.latest(recordingId: recordingId)
    }

    func transcript(id: UUID) async throws -> Transcript? {
        try await inner.transcript(id: id)
    }

    func segments(transcriptId: UUID) async throws -> [SegmentRow] {
        let rows = try await inner.segments(transcriptId: transcriptId)
        return Array(rows.reversed())
    }

    func transcriptId(forSegmentId segmentId: Int64) async throws -> UUID? {
        try await inner.transcriptId(forSegmentId: segmentId)
    }

    func updateAttribution(_ updates: [SegmentAttributionUpdate]) async throws {
        try await inner.updateAttribution(updates)
    }

    func updateSegmentText(segmentId: Int64, text: String, isUserEdited: Bool) async throws {
        try await inner.updateSegmentText(segmentId: segmentId, text: text, isUserEdited: isUserEdited)
    }

    func markSegmentsUserEdited(segmentIds: [Int64]) async throws {
        try await inner.markSegmentsUserEdited(segmentIds: segmentIds)
    }

    func applyTextCorrections(segmentId: Int64, text: String, corrections: [TextCorrection]) async throws {
        try await inner.applyTextCorrections(segmentId: segmentId, text: text, corrections: corrections)
    }

    func search(query: String, limit: Int, offset: Int) async throws -> [SearchHit] {
        try await inner.search(query: query, limit: limit, offset: offset)
    }
}

/// Ошибка вне словаря §3.1 C-016 — ни `StorageError`, ни `PermissionsError`, ни что-либо ещё,
/// что фасад разбирает типизированно; для `test_inv19_...` этого достаточно, поведение фасада
/// не зависит от конкретного типа непойманной ошибки.
private struct UnrelatedTestError: Error {}

/// Делегирует весь `PermissionsPort` фейку, кроме `openSettings(for:)`, который вместо
/// `PermissionsError` бросает `UnrelatedTestError` — см. `test_inv19_...`.
private final class ThrowingOpenSettingsPermissionsPort: PermissionsPort, @unchecked Sendable {
    let inner: FakePermissionsPort

    init(inner: FakePermissionsPort) {
        self.inner = inner
    }

    func snapshot() async -> PermissionSnapshot {
        await inner.snapshot()
    }

    func status(of kind: PermissionKind) async -> PermissionStatus {
        await inner.status(of: kind)
    }

    func request(_ kind: PermissionKind) async -> PermissionRequestOutcome {
        await inner.request(kind)
    }

    func openSettings(for kind: PermissionKind) async throws {
        throw UnrelatedTestError()
    }

    func changes() -> AsyncStream<PermissionSnapshot> {
        inner.changes()
    }

    func note(observed: PermissionStatus, for kind: PermissionKind) async {
        await inner.note(observed: observed, for: kind)
    }

    func isLaunchAtLoginEnabled() async -> Bool {
        await inner.isLaunchAtLoginEnabled()
    }

    func setLaunchAtLogin(_ enabled: Bool) async throws {
        try await inner.setLaunchAtLogin(enabled)
    }
}
