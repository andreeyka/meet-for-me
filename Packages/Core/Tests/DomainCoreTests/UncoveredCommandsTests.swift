//  UncoveredCommandsTests — К47 (`skipMeeting`, группа Х плана MEE-410) и К48(а)
//  (`requestPermission`, та же группа) перечня MEE-401, C-016 v10, MEE-441.
//  `openPermissionSettings`/К48(б) уже покрыты (`AppFacadeImplReadModelsTests+Return.swift`,
//  `ErrorDictionaryTests.swift`, МЕЕ-437) — не дублируются здесь.
//
//  К47: контракт не даёт об этом методе ни одного предложения текста сверх сигнатуры
//  протокола — критерий покрывает буквально это (см. докстринг `skipMeeting` в
//  `AppFacadeImpl+Recording.swift`).
//
//  К48(а): `requestPermission` уже реализован (`AppFacadeImpl.swift`, сквозная обёртка) —
//  этот файл добавляет для него первый тест. Состав `PermissionRequestOutcome` контракт
//  нигде не раскрывает — тест не разбирает возвращённый case, только сверяет его с тем, что
//  отдал фейк (opaque passthrough).

import XCTest
@testable import DomainCore
import DomainTestKit

final class UncoveredCommandsTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let permissions: FakePermissionsPort
    }

    private func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
        let permissions = FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date())
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: permissions,
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            clock: { Date() }
        )
        return Fixture(facade: facade, repositories: repositories, permissions: permissions)
    }

    private func event(id: UUID, title: String) throws -> MeetingEvent {
        try MeetingEvent(
            id: id, sourceConnectorId: "eventkit", externalId: "evt-\(id.uuidString.prefix(8))", icalUid: nil,
            title: title, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_800),
            timeZone: "UTC", isAllDay: false, isCancelled: false, organizer: nil, attendees: [], location: nil,
            bodyText: nil, conference: nil, lastModified: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - К47: skipMeeting

    /// Метод существует, `meetingId: UUID`, `async throws`; на существующей встрече не
    /// бросает; обращается к репозиторию встреч ровно один раз на вызов (действующий текст
    /// перечня MEE-401, `c8741abd`).
    func test_k47_skipMeetingOnExistingMeetingDoesNotThrow() async throws {
        let fixture = makeFixture()
        let meetingId = UUID()
        fixture.repositories.meetings.seed([
            MeetingRecord(
                event: try event(id: meetingId, title: "Созвон"), dedupKey: nil, status: .scheduled, sources: []
            )
        ])

        try await fixture.facade.skipMeeting(meetingId: meetingId)

        XCTAssertEqual(fixture.repositories.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)"), 1)
        let stored = try await fixture.repositories.meetings.meeting(id: meetingId)
        XCTAssertEqual(stored?.status, .skipped)
    }

    // MARK: - К48(а): requestPermission — не бросает, сквозной проход через PermissionsPort

    /// Тип возврата (`async -> PermissionRequestOutcome`, не `throws`) уже гарантирует
    /// «никогда не бросает» на уровне компиляции — мех.-часть критерия. Т-часть: ровно один
    /// вызов `PermissionsPort.request(_:)` с тем же `kind`, и возврат — тот же case, что
    /// отдал фейк, без разбора (opaque passthrough).
    func test_k48a_requestPermission_neverThrowsAndOutcomePassesThrough() async {
        let fixture = makeFixture()
        fixture.permissions.setRequestOutcome(.promptOnUse, for: .screenRecording)

        let outcome = await fixture.facade.requestPermission(.screenRecording)

        XCTAssertEqual(outcome, .promptOnUse)
        XCTAssertEqual(fixture.permissions.requestCallCount(for: .screenRecording), 1)
        XCTAssertEqual(fixture.permissions.requestCallCount(for: .microphone), 0, "вызван только заданный kind")
    }

    /// Второй вектор: другой case проходит так же — не выведен из статуса права (тот же
    /// довод, что докстринг `FakePermissionsPort` даёт для `request(_:)`).
    func test_k48a_requestPermission_differentOutcomePassesThroughUnchanged() async {
        let fixture = makeFixture()
        fixture.permissions.setRequestOutcome(.cannotPrompt, for: .calendars)

        let outcome = await fixture.facade.requestPermission(.calendars)

        XCTAssertEqual(outcome, .cannotPrompt)
        XCTAssertEqual(fixture.permissions.requestCallCount(for: .calendars), 1)
    }
}
