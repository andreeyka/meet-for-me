//  AppFacadeImplReadModelsTests — бэклог приёмки `bf3970d` (08:45 UTC, MEE-420): К5 через
//  подменный репозиторий вразнобой (та же тавтология, что была у К6 до возврата `bf060b8`),
//  и тест инв. 19 на методе из `+Reads.swift` с проверкой `message`, не только `code`. Тот
//  же класс, другой файл — `makeFacade()`/`epoch`/`event` оттуда не `private` специально.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

extension AppFacadeImplReadModelsTests {

    /// К5 (инв. 4), продолжение: `InMemoryMeetingRepository.meetings(from:to:)` отдаёт
    /// строки в порядке вставки — тест, который сеет их уже в ожидаемом порядке, ничего не
    /// говорит о сортировке самого фасада (та же тавтология, что была у К6, см.
    /// `ReversedOrderTranscriptRepository` в `+Return.swift`). `ShuffledOrderMeetingRepository`
    /// отдаёт `meetings(from:to:)` в порядке, обратном порядку вставки.
    func test_k05_meetingsSortedByStartThenMeetingId_notTautologicalOnStorageOrder() async throws {
        let fixture = makeFacade(meetings: { ShuffledOrderMeetingRepository(inner: $0) })
        let facade = fixture.facade
        let repositories = fixture.repositories
        let earlierId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let sameStart = epoch.addingTimeInterval(600)
        let firstId = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        // Порядок вставки — заведомо ПРОТИВОПОЛОЖНЫЙ ожидаемому порядку вывода: если бы
        // фасад полагался на порядок хранилища, а не сортировал сам, этот тест поймал бы
        // регресс, которого К5 в исходном виде поймать не могла.
        let events = try [
            event(id: earlierId, start: sameStart, title: "Раньше по id при равном start"),
            event(id: laterId, start: sameStart, title: "Позже по id при равном start"),
            event(id: firstId, start: epoch, title: "Первая по времени")
        ]
        repositories.meetings.seed(
            events.map { MeetingRecord(event: $0, dedupKey: nil, status: .scheduled, sources: []) }
        )

        let items = try await facade.meetings(from: epoch.addingTimeInterval(-1), to: epoch.addingTimeInterval(3_600))

        XCTAssertEqual(
            items.map(\.title),
            ["Первая по времени", "Раньше по id при равном start", "Позже по id при равном start"]
        )
    }

    /// Инв. 19, §3.1, продолжение: тест на методе из `+Reads.swift` (не `AppFacadeImpl.swift`,
    /// где уже есть `test_inv19_unexpectedPortErrorIsWrappedAsAppInternalError`), с проверкой
    /// `message`, не только `code` — сообщение обязано нести признаки исходной ошибки, а не
    /// быть пустым/родовым текстом.
    func test_inv19_unexpectedRepositoryErrorFromReadsCarriesMessage() async throws {
        let fixture = makeFacade(meetings: { ThrowingMeetingRepository(inner: $0) })

        do {
            _ = try await fixture.facade.meetings(from: epoch, to: epoch.addingTimeInterval(3_600))
            XCTFail("ожидалась посторонняя ошибка, сведённая к app.internalError")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "app.internalError")
            XCTAssertTrue(
                view.message.contains("UnrelatedTestError"),
                "message обязано нести признаки исходной ошибки: \(view.message)"
            )
        }
    }
}

/// К5 (см. выше): делегирует весь `MeetingRepository` внутреннему фейку, кроме
/// `meetings(from:to:)`, который отдаёт строки в порядке, обратном порядку вставки.
private final class ShuffledOrderMeetingRepository: MeetingRepository, @unchecked Sendable {
    let inner: InMemoryMeetingRepository

    init(inner: InMemoryMeetingRepository) {
        self.inner = inner
    }

    func save(_ record: MeetingRecord) async throws {
        try await inner.save(record)
    }

    func save(_ record: MeetingRecord, absorbing meetingIds: [UUID]) async throws {
        try await inner.save(record, absorbing: meetingIds)
    }

    func meeting(id: UUID) async throws -> MeetingRecord? {
        try await inner.meeting(id: id)
    }

    func meeting(dedupKey: DedupKey) async throws -> MeetingRecord? {
        try await inner.meeting(dedupKey: dedupKey)
    }

    func meeting(sourceConnectorId: String, externalId: String) async throws -> MeetingRecord? {
        try await inner.meeting(sourceConnectorId: sourceConnectorId, externalId: externalId)
    }

    func meetings(from: Date, to: Date) async throws -> [MeetingRecord] {
        let records = try await inner.meetings(from: from, to: to)
        return Array(records.reversed())
    }

    func setStatus(_ status: MeetingStatus, meetingId: UUID) async throws {
        try await inner.setStatus(status, meetingId: meetingId)
    }

    func delete(meetingIds: [UUID]) async throws {
        try await inner.delete(meetingIds: meetingIds)
    }
}

/// Ошибка вне словаря §3.1 C-016 — см. `UnrelatedTestError` в `+Return.swift` (тот же приём,
/// отдельное `private`-объявление в своём файле, конфликта нет).
private struct UnrelatedTestError: Error {}

/// Инв. 19 (см. выше): делегирует весь `MeetingRepository` внутреннему фейку, кроме
/// `meetings(from:to:)`, который вместо `StorageError` бросает `UnrelatedTestError`.
private final class ThrowingMeetingRepository: MeetingRepository, @unchecked Sendable {
    let inner: InMemoryMeetingRepository

    init(inner: InMemoryMeetingRepository) {
        self.inner = inner
    }

    func save(_ record: MeetingRecord) async throws {
        try await inner.save(record)
    }

    func save(_ record: MeetingRecord, absorbing meetingIds: [UUID]) async throws {
        try await inner.save(record, absorbing: meetingIds)
    }

    func meeting(id: UUID) async throws -> MeetingRecord? {
        try await inner.meeting(id: id)
    }

    func meeting(dedupKey: DedupKey) async throws -> MeetingRecord? {
        try await inner.meeting(dedupKey: dedupKey)
    }

    func meeting(sourceConnectorId: String, externalId: String) async throws -> MeetingRecord? {
        try await inner.meeting(sourceConnectorId: sourceConnectorId, externalId: externalId)
    }

    func meetings(from: Date, to: Date) async throws -> [MeetingRecord] {
        throw UnrelatedTestError()
    }

    func setStatus(_ status: MeetingStatus, meetingId: UUID) async throws {
        try await inner.setStatus(status, meetingId: meetingId)
    }

    func delete(meetingIds: [UUID]) async throws {
        try await inner.delete(meetingIds: meetingIds)
    }
}
