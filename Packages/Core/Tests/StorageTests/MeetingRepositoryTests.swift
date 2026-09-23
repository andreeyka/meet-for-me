//  MeetingRepositoryTests — К9, К11 перечня MEE-189 (группа B), владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class MeetingRepositoryTests: StorageAsyncTestCase {

    // MARK: - К9

    func testK9_meetingsDedupKeyUniqueness() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let repository = temp.database.meetingRepository()

        // (i) одинаковый непустой dedup_key — вторая встреча не создаётся.
        let sharedKey = DedupKey.icalUid("uid-shared", startEpochSeconds: 100)
        let firstEvent = try TestFixtures.meetingEvent(externalId: "ext-1")
        try await repository.save(MeetingRecord(event: firstEvent, dedupKey: sharedKey, status: .scheduled, sources: []))

        let secondEvent = try TestFixtures.meetingEvent(externalId: "ext-2")
        await XCTAssertThrowsErrorAsync(
            try await repository.save(
                MeetingRecord(event: secondEvent, dedupKey: sharedKey, status: .scheduled, sources: [])
            )
        )
        let secondRead = try await repository.meeting(id: secondEvent.id)
        XCTAssertNil(secondRead, "вторая встреча не создана")

        // (ii) dedup_key == NULL у обеих — уникальности не требует, обе существуют.
        let thirdEvent = try TestFixtures.meetingEvent(externalId: "ext-3")
        let fourthEvent = try TestFixtures.meetingEvent(externalId: "ext-4")
        try await repository.save(MeetingRecord(event: thirdEvent, dedupKey: nil, status: .scheduled, sources: []))
        try await repository.save(MeetingRecord(event: fourthEvent, dedupKey: nil, status: .scheduled, sources: []))
        let thirdRead = try await repository.meeting(id: thirdEvent.id)
        let fourthRead = try await repository.meeting(id: fourthEvent.id)
        XCTAssertNotNil(thirdRead)
        XCTAssertNotNil(fourthRead)

        // (iii) ключ, уже занятый удалённой встречей, — создаётся.
        try await repository.delete(meetingIds: [firstEvent.id])
        let fifthEvent = try TestFixtures.meetingEvent(externalId: "ext-5")
        try await repository.save(MeetingRecord(event: fifthEvent, dedupKey: sharedKey, status: .scheduled, sources: []))
        let fifthRead = try await repository.meeting(id: fifthEvent.id)
        XCTAssertNotNil(fifthRead)
    }

    // MARK: - К11

    func testK11_deleteMeetingCascadesSourcesAttendeesOutputsButKeepsRecordingWithNilMeetingId() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let meetingRepository = temp.database.meetingRepository()
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)

        let attendeeOne = try MeetingEvent.Attendee(
            person: try MeetingEvent.Person(name: "Alice", email: "alice@example.com"),
            responseStatus: .accepted, isOptional: false
        )
        let attendeeTwo = try MeetingEvent.Attendee(
            person: try MeetingEvent.Person(name: "Bob", email: "bob@example.com"),
            responseStatus: .tentative, isOptional: true
        )
        let event = try TestFixtures.meetingEvent(externalId: "ext-k11", attendees: [attendeeOne, attendeeTwo])
        let sources = [
            MeetingSource(sourceConnectorId: "eventkit", externalId: "ext-k11", icalUid: "ical-1",
                          lastModified: TestFixtures.epoch),
            MeetingSource(sourceConnectorId: "stdio", externalId: "ext-k11-b", icalUid: nil,
                          lastModified: TestFixtures.epoch),
        ]
        try await meetingRepository.save(
            MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: sources)
        )

        try temp.database.rawWrite { db in
            for suffix in ["a", "b"] {
                try db.execute(
                    sql: """
                    INSERT INTO meeting_outputs
                        (id, meeting_id, kind, engine, model_version, prompt_version,
                         content_md, created_at, is_user_edited)
                    VALUES (?, ?, 'summary', 'e', 'm1', 'p1', 'text', 0, 0)
                    """,
                    arguments: [UUID().uuidString, event.id.uuidString]
                )
                _ = suffix
            }
        }

        let recordingId = UUID()
        let directory = layout.recordingDirectory(recordingId.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        let manifest = try TestFixtures.recordingManifest(recordingId: recordingId, meetingId: event.id)
        try await recordingRepository.save(RecordingRecord(manifest: manifest, status: .recording))

        try await meetingRepository.delete(meetingIds: [event.id])

        let counts = try temp.database.rawRead { db -> (Int, Int, Int) in
            let sourcesCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM meeting_sources WHERE meeting_id = ?", arguments: [event.id.uuidString]
            ) ?? -1
            let attendeesCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM attendees WHERE meeting_id = ?", arguments: [event.id.uuidString]
            ) ?? -1
            let outputsCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM meeting_outputs WHERE meeting_id = ?", arguments: [event.id.uuidString]
            ) ?? -1
            return (sourcesCount, attendeesCount, outputsCount)
        }
        XCTAssertEqual(counts.0, 0, "meeting_sources каскадом удалены")
        XCTAssertEqual(counts.1, 0, "attendees каскадом удалены")
        XCTAssertEqual(counts.2, 0, "meeting_outputs каскадом удалены")

        // Строка recordings осталась, meeting_id стал NULL — наблюдение через Ш7 (не через manifest).
        let recordingMeetingId: String? = try temp.database.rawRead { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT meeting_id FROM recordings WHERE id = ?", arguments: [recordingId.uuidString]
            )
            return row?["meeting_id"]
        }
        XCTAssertNil(recordingMeetingId)

        // Манифест (K87) не трогается каскадом — прежний meetingId виден через порт.
        let recordingRecord = try await recordingRepository.recording(id: recordingId)
        XCTAssertEqual(recordingRecord?.manifest.meetingId, event.id)

        // Каталог записи и файлы в нём целы.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
    }
}

/// `XCTAssertThrowsError` не принимает `async` выражение напрямую.
func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("ожидалась ошибка", file: file, line: line)
    } catch {
        // ожидаемо
    }
}
