//  UncoveredCommandsTests — К47 (`skipMeeting`, группа Х плана MEE-410) и К48(а)
//  (`requestPermission`, та же группа) перечня MEE-401, C-016 v10, MEE-441.
//  `openPermissionSettings`/К48(б) уже покрыты (`AppFacadeImplReadModelsTests+Return.swift`,
//  `ErrorDictionaryTests.swift`, МЕЕ-437) — не дублируются здесь.
//
//  К47 (возврат РП, приёмка 12:00 UTC, находка 1): `SessionCoordinator.swift` называет
//  `skip` вызовом §3.1, «их зовёт фасад C-016 §4», — тем же классом, что `startRecording`/
//  `stopRecording`. Первая редакция шла мимо машины, через `MeetingRepository.setStatus`
//  напрямую, — правка и разбор в докстринге `skipMeeting` (`AppFacadeImpl+Recording.swift`).
//  Фикстура здесь поэтому — `FakeSessionCoordinator`, не `NoOpSessionCoordinator`.
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
        let sessionCoordinator: FakeSessionCoordinator
    }

    private func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
        let permissions = FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date())
        let sessionCoordinator = FakeSessionCoordinator(log: repositories.log)
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

        XCTAssertEqual(
            fixture.sessionCoordinator.recordedCommands,
            [.skip(meetingId: meetingId, now: Date(timeIntervalSince1970: 1_000))]
        )
        let events = await collectEvents(stream, count: 1, timeoutSeconds: 1)
        XCTAssertEqual(events.count, 1, "\(events)")
    }

    /// Отказ `SessionCoordinator.skip` пробрасывается через `wrap(_:SessionError)` — тот же
    /// путь, что `startRecording`/`stopRecording` (`AppFacadeImpl+Recording.swift`).
    func test_k47_skipMeeting_sessionCoordinatorFailureWrapped() async throws {
        let fixture = makeFixture()
        let meetingId = UUID()
        fixture.sessionCoordinator.fail(.skip, with: .noSuchMeeting(meetingId: meetingId))

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
