//  RenamePersonTests — К46 (группа Ф плана MEE-410, перечень MEE-401, C-016 v10, MEE-441).
//
//  `renamePerson` не назван ни одним отдельным инвариантом 1-28 и ничем сверх голой сигнатуры
//  протокола (возврат РП п.6, действующий текст перечня) — тесты ниже проверяют буквально
//  это: `displayName` применяется, отказ на несуществующем `personId` пробрасывается, и по
//  инв. 15 публикуется хотя бы одно событие (какое именно — контракт не называет, см.
//  докстринг `AppFacadeImpl+RenamePerson.swift`).

import XCTest
@testable import DomainCore
import DomainTestKit

final class RenamePersonTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
    }

    private func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
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
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            clock: { Date() }
        )
        return Fixture(facade: facade, repositories: repositories)
    }

    /// `displayName` применяется к существующей записи; по инв. 15 публикуется хотя бы одно
    /// событие — критерий не сужает, какое именно (см. докстринг файла реализации).
    func test_k46_renamePerson_updatesRecordAndPublishesAtLeastOneEvent() async throws {
        let fixture = makeFixture()
        let personId = UUID()
        fixture.repositories.persons.seed([
            PersonRecord(id: personId, displayName: "Старое имя", emails: [], isMe: false)
        ])
        let stream = fixture.facade.events()

        try await fixture.facade.renamePerson(personId: personId, displayName: "Новое имя")

        let renamed = try await fixture.repositories.persons.person(id: personId)
        XCTAssertEqual(renamed?.displayName, "Новое имя")
        let events = await collectEvents(stream, count: 1, timeoutSeconds: 1)
        XCTAssertEqual(events.count, 1, "\(events)")
    }

    /// Несуществующий `personId` — отказ; конкретная форма `AppFacadeError`/строка `entity`
    /// контрактом не названы (`notFound(entity: String, id: String)` — `String`, не
    /// перечисление) — критерий проверяет только сам факт отказа.
    func test_k46_renamePerson_unknownPersonIdThrows() async throws {
        let fixture = makeFixture()

        var thrown: Error?
        do {
            try await fixture.facade.renamePerson(personId: UUID(), displayName: "Кто-то")
        } catch {
            thrown = error
        }
        XCTAssertNotNil(thrown, "ожидался отказ — форма ошибки контрактом не названа, см. докстринг файла")
    }
}
