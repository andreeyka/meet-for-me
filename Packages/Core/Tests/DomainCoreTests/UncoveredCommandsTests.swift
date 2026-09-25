//  UncoveredCommandsTests — К47 (`skipMeeting`, группа Х плана MEE-410) и К48(а)
//  (`requestPermission`, та же группа) перечня MEE-401, C-016 v10, MEE-441.
//  `openPermissionSettings`/К48(б) уже покрыты (`AppFacadeImplReadModelsTests+Return.swift`,
//  `ErrorDictionaryTests.swift`, МЕЕ-437) — не дублируются здесь.
//
//  К47 (возврат РП, приёмка 12:00 UTC, находка 1): `SessionCoordinator.swift` называет
//  `skip` вызовом §3.1, «их зовёт фасад C-016 §4», — тем же классом, что `startRecording`/
//  `stopRecording`. Первая редакция шла мимо машины, через `MeetingRepository.setStatus`
//  напрямую, — правка и разбор в докстринге `skipMeeting` (`AppFacadeImpl+Recording.swift`).
//
//  `TestSkipSessionCoordinator` — СВОЙ, а не `DomainTestKit.FakeSessionCoordinator`: К88
//  плана MEE-288 (`SessionCoordinatorFakeTraceTests.swift`) красит любой файл в `Tests/
//  DomainCoreTests/`, кодово ссылающийся на тот фейк, кроме его собственного теста —
//  тот же довод и то же решение, что уже принял `RecordingCommandsTests.swift`
//  (`TestSessionCoordinator`, приёмка РП MEE-420, 09:50 UTC: «свои заглушки координатора —
//  допустимое решение, сторож не ослаблен»).
//
//  К48(а): `requestPermission` уже реализован (`AppFacadeImpl.swift`, сквозная обёртка) —
//  этот файл добавляет для него первый тест. Состав `PermissionRequestOutcome` контракт
//  нигде не раскрывает — тест не разбирает возвращённый case, только сверяет его с тем, что
//  отдал фейк (opaque passthrough); табличный вектор — все четыре случая (возврат РП, та же
//  приёмка, «мелочи»: раньше проверялись только два из четырёх).

import XCTest
@testable import DomainCore
import DomainTestKit

final class UncoveredCommandsTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let permissions: FakePermissionsPort
        let sessionCoordinator: TestSkipSessionCoordinator
    }

    private func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
        let permissions = FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date())
        let sessionCoordinator = TestSkipSessionCoordinator()
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: permissions,
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: sessionCoordinator,
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            clock: { Date(timeIntervalSince1970: 1_000) }
        )
        return Fixture(
            facade: facade, repositories: repositories, permissions: permissions, sessionCoordinator: sessionCoordinator
        )
    }

    // MARK: - К47: skipMeeting

    /// Метод существует, `meetingId: UUID`, `async throws`; на существующей встрече не
    /// бросает; обращается к `SessionCoordinator.skip(meetingId:now:)` ровно один раз на
    /// вызов, тем же `meetingId` и тем же моментом, что даёт `clock()` (симметрично
    /// `startRecording`/`stopRecording`). Инв. 15: публикует хотя бы одно событие.
    func test_k47_skipMeetingOnExistingMeetingDoesNotThrow() async throws {
        let fixture = makeFixture()
        let meetingId = UUID()
        let stream = fixture.facade.events()

        try await fixture.facade.skipMeeting(meetingId: meetingId)

        let calls = fixture.sessionCoordinator.recordedSkipCalls
        XCTAssertEqual(calls.count, 1, "\(calls)")
        XCTAssertEqual(calls.first?.meetingId, meetingId)
        XCTAssertEqual(calls.first?.now, Date(timeIntervalSince1970: 1_000))
        let events = await collectEvents(stream, count: 1, timeoutSeconds: 1)
        XCTAssertEqual(events.count, 1, "\(events)")
    }

    /// Отказ `SessionCoordinator.skip` пробрасывается через `wrap(_:SessionError)` — тот же
    /// путь, что `startRecording`/`stopRecording` (`AppFacadeImpl+Recording.swift`).
    func test_k47_skipMeeting_sessionCoordinatorFailureWrapped() async throws {
        let fixture = makeFixture()
        let meetingId = UUID()
        fixture.sessionCoordinator.failSkip(with: .noSuchMeeting(meetingId: meetingId))

        do {
            try await fixture.facade.skipMeeting(meetingId: meetingId)
            XCTFail("ожидался отказ")
        } catch AppFacadeError.notFound(let entity, let id) {
            XCTAssertEqual(entity, "Meeting")
            XCTAssertEqual(id, meetingId.uuidString)
        }
    }

    // MARK: - К48(а): requestPermission — не бросает, сквозной проход через PermissionsPort

    private struct OutcomeRow {
        let outcome: PermissionRequestOutcome
        let kind: PermissionKind
    }

    /// Все четыре случая `PermissionRequestOutcome` (C-007 v7: `granted`/`denied`/
    /// `cannotPrompt`/`promptOnUse`) — каждый проходит насквозь без разбора, на своём
    /// `PermissionKind`, чтобы заодно сверить «вызван только заданный kind».
    private var outcomeRows: [OutcomeRow] {
        [
            OutcomeRow(outcome: .granted, kind: .microphone),
            OutcomeRow(outcome: .denied, kind: .systemAudioRecording),
            OutcomeRow(outcome: .cannotPrompt, kind: .calendars),
            OutcomeRow(outcome: .promptOnUse, kind: .screenRecording)
        ]
    }

    /// Тип возврата (`async -> PermissionRequestOutcome`, не `throws`) уже гарантирует
    /// «никогда не бросает» на уровне компиляции — мех.-часть критерия. Т-часть: ровно один
    /// вызов `PermissionsPort.request(_:)` с тем же `kind`, и возврат — тот же case, что
    /// отдал фейк, без разбора (opaque passthrough) — на всех четырёх исходах разом.
    func test_k48a_requestPermission_allFourOutcomesPassThroughUnchanged() async {
        for row in outcomeRows {
            let fixture = makeFixture()
            fixture.permissions.setRequestOutcome(row.outcome, for: row.kind)

            let outcome = await fixture.facade.requestPermission(row.kind)

            XCTAssertEqual(outcome, row.outcome, "\(row.outcome)")
            XCTAssertEqual(fixture.permissions.requestCallCount(for: row.kind), 1, "\(row.outcome)")
        }
    }

    func test_k48a_requestPermission_callsOnlyTheGivenKind() async {
        let fixture = makeFixture()
        fixture.permissions.setRequestOutcome(.promptOnUse, for: .screenRecording)

        _ = await fixture.facade.requestPermission(.screenRecording)

        XCTAssertEqual(fixture.permissions.requestCallCount(for: .microphone), 0, "вызван только заданный kind")
    }
}

/// См. докстринг файла — К88 (`SessionCoordinatorFakeTraceTests.swift`) запрещает ссылаться
/// на `DomainTestKit.FakeSessionCoordinator` вне его собственного теста; несёт только то,
/// что нужно К47: запись вызовов `skip` и отказ по требованию.
private final class TestSkipSessionCoordinator: SessionCoordinator, @unchecked Sendable {
    private let lock = NSLock()
    private var skipCalls: [(meetingId: UUID, now: Date)] = []
    private var skipError: SessionError?

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func failSkip(with error: SessionError) {
        locked { skipError = error }
    }

    var recordedSkipCalls: [(meetingId: UUID, now: Date)] {
        locked { skipCalls }
    }

    func sessions() async -> [SessionSnapshot] { [] }
    func session(id: UUID) async -> SessionSnapshot? { nil }
    func prompts() async -> [SessionPrompt] { [] }
    func changes() -> AsyncStream<SessionChange> { AsyncStream { _ in } }
    func startRecording(meetingId: UUID?, now: Date) async throws -> UUID { UUID() }
    func stopRecording(recordingId: UUID, now: Date) async throws {}

    func skip(meetingId: UUID, now: Date) async throws {
        locked { skipCalls.append((meetingId: meetingId, now: now)) }
        if let error = locked({ skipError }) {
            throw error
        }
    }

    func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws {}
    func start(now: Date) async {}
    func tick(now: Date) async {}
    func stop() async {}
}
