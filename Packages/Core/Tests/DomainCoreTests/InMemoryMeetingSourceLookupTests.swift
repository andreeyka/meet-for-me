//  MEE-352 (IR-118): InMemoryMeetingRepository.meeting(sourceConnectorId:externalId:) —
//  C-010 v10, инвариант 30.
//
//  Отдельный файл, а не ещё один `extension InMemoryRepositoriesTests` в
//  `InMemoryRepositoriesTests.swift`: тот файл уже стоял у порога `file_length` SwiftLint
//  (397 из 400 строк) — здесь по объёму, не по смыслу, тем же приёмом, что уже разводит
//  другие файлы этого дерева (см. шапки `JobQueueEngineReview.swift`/`Lifecycle.swift`,
//  `RepositoriesExtended.swift`).

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryMeetingSourceLookupTests: XCTestCase {

    /// «Пара — первичный ключ `meeting_sources`, результат не более чем один; полный
    /// перебор `meetings` не нужен». Одна встреча с двумя источниками — обе пары находят
    /// её же; половинчатое совпадение и отсутствующая пара — `nil`, не отказ.
    func test_mee352_meetingRepository_meetingBySourcePairFindsRecordOrNil() async throws {
        let repositories = InMemoryRepositories()
        let event = MeetingEventFixtures.oneOnOneZoom
        let firstSource = MeetingSource(
            sourceConnectorId: "eventkit", externalId: "ext-30-a", icalUid: nil,
            lastModified: Date(timeIntervalSince1970: 1_789_041_600)
        )
        let secondSource = MeetingSource(
            sourceConnectorId: "graph:work", externalId: "ext-30-b", icalUid: nil,
            lastModified: Date(timeIntervalSince1970: 1_789_041_600)
        )
        repositories.meetings.seed([
            MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: [firstSource, secondSource])
        ])

        let foundByFirst = try await repositories.meetings.meeting(
            sourceConnectorId: "eventkit", externalId: "ext-30-a"
        )
        XCTAssertEqual(foundByFirst?.event.id, event.id)

        let foundBySecond = try await repositories.meetings.meeting(
            sourceConnectorId: "graph:work", externalId: "ext-30-b"
        )
        XCTAssertEqual(foundBySecond?.event.id, event.id, "у одной встречи несколько источников — любой находит её")

        let halfMatch = try await repositories.meetings.meeting(
            sourceConnectorId: "eventkit", externalId: "ext-30-b"
        )
        XCTAssertNil(halfMatch, "пара — обе половины вместе, не порознь")

        let missing = try await repositories.meetings.meeting(
            sourceConnectorId: "eventkit", externalId: "нет-такой"
        )
        XCTAssertNil(missing, "пары нет — nil, а не отказ")
    }

    // MARK: - Инвариант 30 (C-010 v14): пара уникальна у ДРУГОЙ встречи

    /// Пара (`sourceConnectorId`, `externalId`), уже занятая одной встречей, — `save`
    /// другой встречи с той же парой бросает `constraintViolation`, не молча перезаписывает.
    func test_mee357_save_pairAtAnotherMeetingThrowsConstraintViolation() async throws {
        let repositories = InMemoryRepositories()
        let source = MeetingSource(
            sourceConnectorId: "eventkit", externalId: "ext-30-shared", icalUid: nil,
            lastModified: Date(timeIntervalSince1970: 1_789_041_600)
        )
        try await repositories.meetings.save(MeetingRecord(
            event: MeetingEventFixtures.oneOnOneZoom, dedupKey: nil, status: .scheduled, sources: [source]
        ))

        do {
            try await repositories.meetings.save(MeetingRecord(
                event: MeetingEventFixtures.withoutConference, dedupKey: nil, status: .scheduled, sources: [source]
            ))
            XCTFail("ожидался constraintViolation — пара уже занята другой встречей")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }
    }

    /// Повторное сохранение ТОЙ ЖЕ встречи с той же парой — не самоклэш, проходит.
    func test_mee357_save_sameMeetingWithSamePairSucceeds() async throws {
        let repositories = InMemoryRepositories()
        let source = MeetingSource(
            sourceConnectorId: "eventkit", externalId: "ext-30-same", icalUid: nil,
            lastModified: Date(timeIntervalSince1970: 1_789_041_600)
        )
        let event = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(MeetingRecord(
            event: event, dedupKey: nil, status: .scheduled, sources: [source]
        ))
        try await repositories.meetings.save(MeetingRecord(
            event: event, dedupKey: nil, status: .armed, sources: [source]
        ))

        let updated = try await repositories.meetings.meeting(id: event.id)
        XCTAssertEqual(updated?.status, .armed, "второй save той же встречи прошёл и обновил статус")
    }
}
