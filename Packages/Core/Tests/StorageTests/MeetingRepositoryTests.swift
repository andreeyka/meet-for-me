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
        try await Self.save(firstEvent, dedupKey: sharedKey, repository: repository)

        let secondEvent = try TestFixtures.meetingEvent(externalId: "ext-2")
        await XCTAssertThrowsErrorAsync(
            try await Self.save(secondEvent, dedupKey: sharedKey, repository: repository)
        )
        let secondRead = try await repository.meeting(id: secondEvent.id)
        XCTAssertNil(secondRead, "вторая встреча не создана")

        // (ii) dedup_key == NULL у обеих — уникальности не требует, обе существуют.
        let thirdEvent = try TestFixtures.meetingEvent(externalId: "ext-3")
        let fourthEvent = try TestFixtures.meetingEvent(externalId: "ext-4")
        try await Self.save(thirdEvent, dedupKey: nil, repository: repository)
        try await Self.save(fourthEvent, dedupKey: nil, repository: repository)
        let thirdRead = try await repository.meeting(id: thirdEvent.id)
        let fourthRead = try await repository.meeting(id: fourthEvent.id)
        XCTAssertNotNil(thirdRead)
        XCTAssertNotNil(fourthRead)

        // (iii) ключ, уже занятый удалённой встречей, — создаётся.
        try await repository.delete(meetingIds: [firstEvent.id])
        let fifthEvent = try TestFixtures.meetingEvent(externalId: "ext-5")
        try await Self.save(fifthEvent, dedupKey: sharedKey, repository: repository)
        let fifthRead = try await repository.meeting(id: fifthEvent.id)
        XCTAssertNotNil(fifthRead)
    }

    private static func save(
        _ event: MeetingEvent, dedupKey: DedupKey?, repository: MeetingRepository
    ) async throws {
        try await repository.save(MeetingRecord(event: event, dedupKey: dedupKey, status: .scheduled, sources: []))
    }

    // MARK: - Инвариант 30 (C-010 v10, IR-118, MEE-348)

    /// «Пара — первичный ключ `meeting_sources`, результат не более чем один; полный
    /// перебор `meetings` не нужен». Прямая точечная выборка, не полное чтение таблицы.
    func test_invariant30_meetingBySourcePairFindsRecordOrNil() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let repository = temp.database.meetingRepository()

        let event = try TestFixtures.meetingEvent(externalId: "ext-30")
        let sources = [
            MeetingSource(
                sourceConnectorId: "eventkit", externalId: "ext-30-a", icalUid: nil,
                lastModified: TestFixtures.epoch
            ),
            MeetingSource(
                sourceConnectorId: "graph:work", externalId: "ext-30-b", icalUid: nil,
                lastModified: TestFixtures.epoch
            )
        ]
        try await repository.save(MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: sources))

        let foundByFirst = try await repository.meeting(sourceConnectorId: "eventkit", externalId: "ext-30-a")
        XCTAssertEqual(foundByFirst?.event.id, event.id)

        let foundBySecond = try await repository.meeting(sourceConnectorId: "graph:work", externalId: "ext-30-b")
        XCTAssertEqual(foundBySecond?.event.id, event.id, "у одной встречи несколько источников — любой находит её")

        let halfMatch = try await repository.meeting(sourceConnectorId: "eventkit", externalId: "ext-30-b")
        XCTAssertNil(halfMatch, "пара — обе половины вместе, не порознь")

        let missing = try await repository.meeting(sourceConnectorId: "eventkit", externalId: "нет-такой")
        XCTAssertNil(missing, "пары нет — nil, а не отказ")
    }

    // MARK: - К11

    func testK11_deleteMeetingCascadesSourcesAttendeesOutputsButKeepsRecordingWithNilMeetingId() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let meetingRepository = temp.database.meetingRepository()
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)

        let event = try await Self.seedMeetingWithChildren(
            meetingRepository: meetingRepository, database: temp.database
        )
        let recordingId = try await Self.seedRecording(
            meetingId: event.id, layout: layout, repository: recordingRepository
        )

        try await meetingRepository.delete(meetingIds: [event.id])

        try await Self.assertChildrenCascaded(meetingId: event.id, database: temp.database)
        try await Self.assertRecordingSurvivedWithNilMeetingId(
            recordingId: recordingId, originalMeetingId: event.id, layout: layout,
            database: temp.database, repository: recordingRepository
        )
    }

    /// Встреча с двумя источниками, двумя участниками и двумя `meeting_outputs`
    /// (вставлены мимо репозитория — своего порта у этой части ещё нет).
    private static func seedMeetingWithChildren(
        meetingRepository: MeetingRepository, database: StorageDatabase
    ) async throws -> MeetingEvent {
        let attendees = try [
            MeetingEvent.Attendee(
                person: try MeetingEvent.Person(name: "Alice", email: "alice@example.com"),
                responseStatus: .accepted, isOptional: false
            ),
            MeetingEvent.Attendee(
                person: try MeetingEvent.Person(name: "Bob", email: "bob@example.com"),
                responseStatus: .tentative, isOptional: true
            )
        ]
        let event = try TestFixtures.meetingEvent(externalId: "ext-k11", attendees: attendees)
        let sources = [
            MeetingSource(sourceConnectorId: "eventkit", externalId: "ext-k11", icalUid: "ical-1",
                          lastModified: TestFixtures.epoch),
            MeetingSource(sourceConnectorId: "stdio", externalId: "ext-k11-b", icalUid: nil,
                          lastModified: TestFixtures.epoch)
        ]
        try await meetingRepository.save(
            MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: sources)
        )
        try database.rawWrite { db in
            for _ in 0..<2 {
                try db.execute(
                    sql: """
                    INSERT INTO meeting_outputs
                        (id, meeting_id, kind, engine, model_version, prompt_version,
                         content_md, created_at, is_user_edited)
                    VALUES (?, ?, 'summary', 'e', 'm1', 'p1', 'text', 0, 0)
                    """,
                    arguments: [UUID().uuidString, event.id.uuidString]
                )
            }
        }
        return event
    }

    private static func seedRecording(
        meetingId: UUID, layout: FileLayout, repository: RecordingRepository
    ) async throws -> UUID {
        let recordingId = UUID()
        let directory = layout.recordingDirectory(recordingId.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        let manifest = try TestFixtures.recordingManifest(recordingId: recordingId, meetingId: meetingId)
        try await repository.save(RecordingRecord(manifest: manifest, status: .recording))
        return recordingId
    }

    private static func assertChildrenCascaded(meetingId: UUID, database: StorageDatabase) throws {
        let idText = meetingId.uuidString
        let sourcesCount = try database.rawRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_sources WHERE meeting_id = ?", arguments: [idText])
        }
        let attendeesCount = try database.rawRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attendees WHERE meeting_id = ?", arguments: [idText])
        }
        let outputsCount = try database.rawRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_outputs WHERE meeting_id = ?", arguments: [idText])
        }
        XCTAssertEqual(sourcesCount, 0, "meeting_sources каскадом удалены")
        XCTAssertEqual(attendeesCount, 0, "attendees каскадом удалены")
        XCTAssertEqual(outputsCount, 0, "meeting_outputs каскадом удалены")
    }

    private static func assertRecordingSurvivedWithNilMeetingId(
        recordingId: UUID, originalMeetingId: UUID, layout: FileLayout,
        database: StorageDatabase, repository: RecordingRepository
    ) async throws {
        // Строка recordings осталась, meeting_id стал NULL — наблюдение через Ш7 (не через manifest).
        let recordingMeetingId: String? = try database.rawRead { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT meeting_id FROM recordings WHERE id = ?", arguments: [recordingId.uuidString]
            )
            return row?["meeting_id"]
        }
        XCTAssertNil(recordingMeetingId)

        // Манифест (K87) не трогается каскадом — прежний meetingId виден через порт.
        let recordingRecord = try await repository.recording(id: recordingId)
        XCTAssertEqual(recordingRecord?.manifest.meetingId, originalMeetingId)

        // Каталог записи и файлы в нём целы.
        let manifestPath = layout.manifestURL(recordingId.uuidString).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestPath))
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
