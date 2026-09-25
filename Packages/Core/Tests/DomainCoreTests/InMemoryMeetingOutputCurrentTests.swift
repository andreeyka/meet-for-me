//  InMemoryMeetingOutputCurrentTests — К107 перечня MEE-189 (дельта Э), MEE-419.
//  Те же векторы, что `MeetingOutputCurrentByCreatedAtTests.swift` (StorageTests, GRDB), на
//  фейке `InMemoryMeetingOutputRepository`: контракт требует, чтобы тест на фейке ловил то
//  же, что тест на настоящей базе (§«Фейк для тестов» C-010).

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryMeetingOutputCurrentTests: XCTestCase {

    /// Унаследованная от проигравшего выдача новее — она и текущая.
    func test_transferredFromLoserIsNewer() async throws {
        let repositories = InMemoryRepositories()
        let winnerEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = MeetingEventFixtures.withoutConference
        try await repositories.meetings.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let olderOutput = MeetingOutput(
            id: UUID(), meetingId: winnerEvent.id, kind: .summary, engine: "e", modelVersion: "m1",
            promptVersion: "p1", contentMarkdown: "старая", structuredJson: nil,
            createdAt: Date(timeIntervalSince1970: 0), isUserEdited: false
        )
        repositories.meetingOutputs.seed([olderOutput])
        let newerOutput = MeetingOutput(
            id: UUID(), meetingId: loserEvent.id, kind: .summary, engine: "e", modelVersion: "m2",
            promptVersion: "p1", contentMarkdown: "новая", structuredJson: nil,
            createdAt: Date(timeIntervalSince1970: 3_600), isUserEdited: false
        )
        repositories.meetingOutputs.seed([newerOutput])

        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: []),
            absorbing: [loserEvent.id]
        )

        let outputs = try await repositories.meetingOutputs.outputs(meetingId: winnerEvent.id)
        XCTAssertEqual(Set(outputs.map(\.id)), [olderOutput.id, newerOutput.id], "обе выдачи сохранены")
        let current = outputs.filter { $0.kind == .summary }.max { $0.createdAt < $1.createdAt }
        XCTAssertEqual(current?.id, newerOutput.id, "текущая — с максимальным created_at")
    }

    /// Собственная выдача победителя новее унаследованной — она и остаётся текущей.
    func test_winnersOwnIsNewer() async throws {
        let repositories = InMemoryRepositories()
        let winnerEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = MeetingEventFixtures.withoutConference
        try await repositories.meetings.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let newerOutput = MeetingOutput(
            id: UUID(), meetingId: winnerEvent.id, kind: .summary, engine: "e", modelVersion: "m1",
            promptVersion: "p1", contentMarkdown: "новая", structuredJson: nil,
            createdAt: Date(timeIntervalSince1970: 3_600), isUserEdited: false
        )
        repositories.meetingOutputs.seed([newerOutput])
        let olderOutput = MeetingOutput(
            id: UUID(), meetingId: loserEvent.id, kind: .summary, engine: "e", modelVersion: "m2",
            promptVersion: "p1", contentMarkdown: "старая", structuredJson: nil,
            createdAt: Date(timeIntervalSince1970: 0), isUserEdited: false
        )
        repositories.meetingOutputs.seed([olderOutput])

        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: []),
            absorbing: [loserEvent.id]
        )

        let outputs = try await repositories.meetingOutputs.outputs(meetingId: winnerEvent.id)
        let current = outputs.filter { $0.kind == .summary }.max { $0.createdAt < $1.createdAt }
        XCTAssertEqual(current?.id, newerOutput.id, "текущая осталась своя, унаследованная её не вытеснила")
    }
}
