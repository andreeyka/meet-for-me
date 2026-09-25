//  MeetingOutputCurrentByCreatedAtTests — К107 перечня MEE-189 (дельта Э), MEE-419.
//
//  C-010 v22 инв. 33: после `save(_:absorbing:)` у победителя может оказаться несколько
//  `meeting_outputs` одного `kind` (свой и унаследованный от проигравшего) — текущим
//  считается тот, у которого `created_at` максимален. `outputs(meetingId:)` порядка не
//  гарантирует (C-010): выбор максимума — дело вызывающего, порт для этого отдельного
//  метода не даёт (проверено — его нет в `MeetingOutputRepository`), поэтому тест сам
//  находит максимум по `outputs(meetingId:)`, а не полагается на порядок строк ответа.

import XCTest
import DomainCore
@testable import Storage

final class MeetingOutputCurrentByCreatedAtTests: StorageAsyncTestCase {

    /// Унаследованная от проигравшего выдача новее — она и текущая.
    func testCurrentOutput_transferredFromLoserIsNewer() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetingRepository = temp.database.meetingRepository()
        let outputRepository = temp.database.meetingOutputRepository()

        let winnerEvent = try TestFixtures.meetingEvent(externalId: "ext-current-1-winner")
        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = try TestFixtures.meetingEvent(externalId: "ext-current-1-loser")
        try await meetingRepository.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let olderOutput = MeetingOutput(
            id: UUID(), meetingId: winnerEvent.id, kind: .summary, engine: "e", modelVersion: "m1",
            promptVersion: "p1", contentMarkdown: "старая", structuredJson: nil,
            createdAt: TestFixtures.epoch, isUserEdited: false
        )
        try await outputRepository.save(olderOutput)
        let newerOutput = MeetingOutput(
            id: UUID(), meetingId: loserEvent.id, kind: .summary, engine: "e", modelVersion: "m2",
            promptVersion: "p1", contentMarkdown: "новая", structuredJson: nil,
            createdAt: TestFixtures.epoch.addingTimeInterval(3_600), isUserEdited: false
        )
        try await outputRepository.save(newerOutput)

        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: []),
            absorbing: [loserEvent.id]
        )

        let outputs = try await outputRepository.outputs(meetingId: winnerEvent.id)
        XCTAssertEqual(Set(outputs.map(\.id)), [olderOutput.id, newerOutput.id], "обе выдачи сохранены")
        let current = outputs.filter { $0.kind == .summary }.max { $0.createdAt < $1.createdAt }
        XCTAssertEqual(current?.id, newerOutput.id, "текущая — с максимальным created_at")
    }

    /// Собственная выдача победителя новее унаследованной — она и остаётся текущей;
    /// симметричный вектор первому, чтобы «текущая» не подменялась «перенесённой».
    func testCurrentOutput_winnersOwnIsNewer() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetingRepository = temp.database.meetingRepository()
        let outputRepository = temp.database.meetingOutputRepository()

        let winnerEvent = try TestFixtures.meetingEvent(externalId: "ext-current-2-winner")
        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = try TestFixtures.meetingEvent(externalId: "ext-current-2-loser")
        try await meetingRepository.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let newerOutput = MeetingOutput(
            id: UUID(), meetingId: winnerEvent.id, kind: .summary, engine: "e", modelVersion: "m1",
            promptVersion: "p1", contentMarkdown: "новая", structuredJson: nil,
            createdAt: TestFixtures.epoch.addingTimeInterval(3_600), isUserEdited: false
        )
        try await outputRepository.save(newerOutput)
        let olderOutput = MeetingOutput(
            id: UUID(), meetingId: loserEvent.id, kind: .summary, engine: "e", modelVersion: "m2",
            promptVersion: "p1", contentMarkdown: "старая", structuredJson: nil,
            createdAt: TestFixtures.epoch, isUserEdited: false
        )
        try await outputRepository.save(olderOutput)

        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: []),
            absorbing: [loserEvent.id]
        )

        let outputs = try await outputRepository.outputs(meetingId: winnerEvent.id)
        let current = outputs.filter { $0.kind == .summary }.max { $0.createdAt < $1.createdAt }
        XCTAssertEqual(current?.id, newerOutput.id, "текущая осталась своя, унаследованная её не вытеснила")
    }
}
