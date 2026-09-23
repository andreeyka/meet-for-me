//  RecordingRepositoryTests — К17—К19 перечня MEE-189 (группа C), владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class RecordingRepositoryTests: StorageAsyncTestCase {

    // MARK: - К17

    func testK17_directoryNameIsRecordingIdUppercaseWithDashesAndUnique() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let repository = temp.database.recordingRepository(fileLayout: layout)

        let recordingId = UUID()
        let manifest = try TestFixtures.recordingManifest(recordingId: recordingId)
        try await repository.save(RecordingRecord(manifest: manifest, status: .recording))

        let directoryName = try temp.database.rawRead { db in
            try String.fetchOne(db, sql: "SELECT directory_name FROM recordings WHERE id = ?",
                                 arguments: [recordingId.uuidString])
        }
        XCTAssertEqual(directoryName, recordingId.uuidString)
        XCTAssertEqual(directoryName, recordingId.uuidString.uppercased())
        XCTAssertFalse(directoryName?.contains("{") ?? true)

        // Вторая вставка с тем же `directory_name`, но другим id — через Ш7.
        XCTAssertThrowsError(
            try temp.database.rawWrite { db in
                try db.execute(
                    sql: """
                    INSERT INTO recordings
                        (id, meeting_id, directory_name, started_at, manifest_json,
                         is_finalized, status, created_at, updated_at)
                    VALUES (?, NULL, ?, 0, '{}', 0, 'recording', 0, 0)
                    """,
                    arguments: [UUID().uuidString, recordingId.uuidString]
                )
            }
        )
    }

    // MARK: - К18

    func testK18_saveDoesNotTouchFilesOnDisk() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let repository = temp.database.recordingRepository(fileLayout: layout)

        let recordingId = UUID()
        let directory = layout.recordingDirectory(recordingId.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let micData = Data("mic-bytes".utf8)
        let systemData = Data("system-bytes".utf8)
        let manifestData = Data("{\"onDisk\":true}".utf8)
        try micData.write(to: directory.appendingPathComponent("audio-mic.caf"))
        try systemData.write(to: directory.appendingPathComponent("audio-system.caf"))
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"))

        let before = try Self.snapshot(of: directory)

        let manifest = try TestFixtures.recordingManifest(recordingId: recordingId)
        try await repository.save(RecordingRecord(manifest: manifest, status: .recording))

        let after = try Self.snapshot(of: directory)
        XCTAssertEqual(before, after, "каталог не тронут ни одним файлом")

        let storedManifestJSON = try temp.database.rawRead { db in
            try String.fetchOne(db, sql: "SELECT manifest_json FROM recordings WHERE id = ?",
                                 arguments: [recordingId.uuidString])
        }
        XCTAssertNotNil(storedManifestJSON)
        XCTAssertFalse(storedManifestJSON?.contains("onDisk") ?? true, "база хранит переданный манифест, не файл")
    }

    // MARK: - К19

    func testK19_deleteFilesTrueRemovesDirectoryFalseKeepsIt() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let repository = temp.database.recordingRepository(fileLayout: layout)

        let firstId = UUID()
        let secondId = UUID()
        for id in [firstId, secondId] {
            let directory = layout.recordingDirectory(id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appendingPathComponent("manifest.json"))
            let manifest = try TestFixtures.recordingManifest(recordingId: id)
            try await repository.save(RecordingRecord(manifest: manifest, status: .recording))
        }

        try await repository.delete(recordingId: firstId, deleteFiles: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.recordingDirectory(firstId.uuidString).path))
        let firstRow = try await repository.recording(id: firstId)
        XCTAssertNil(firstRow)

        try await repository.delete(recordingId: secondId, deleteFiles: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.recordingDirectory(secondId.uuidString).path))
        let manifestStillThere = FileManager.default.fileExists(
            atPath: layout.manifestURL(secondId.uuidString).path
        )
        XCTAssertTrue(manifestStillThere)
        let secondRow = try await repository.recording(id: secondId)
        XCTAssertNil(secondRow)

        // Отдельный вход: `deleteFiles: true` на записи без каталога на диске — без эффекта.
        let thirdId = UUID()
        let thirdManifest = try TestFixtures.recordingManifest(recordingId: thirdId)
        try await repository.save(RecordingRecord(manifest: thirdManifest, status: .recording))
        try await repository.delete(recordingId: thirdId, deleteFiles: true)
    }

    // MARK: - Инвариант 7 (C-010 v8): meeting_id пишется из манифеста только при вставке

    /// IR-113 (МЕЕ-326), закрыт изданием C-010 v8: `save(_:)` пишет `meeting_id`
    /// из `manifest.meetingId` только при вставке НОВОЙ строки; у уже
    /// существующей строки колонку не трогает ни в какую сторону — ни до
    /// каскада (другим значением того же поля), ни после него (значением из
    /// манифеста, ссылающимся на уже удалённую встречу).
    func testInv7v8_meetingIdWrittenOnlyOnInsertNotOnUpdateBeforeOrAfterCascade() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let meetingRepository = temp.database.meetingRepository()

        let meetingA = try TestFixtures.meetingEvent(externalId: "ext-inv7-a")
        let meetingB = try TestFixtures.meetingEvent(externalId: "ext-inv7-b")
        try await meetingRepository.save(MeetingRecord(event: meetingA, dedupKey: nil, status: .scheduled, sources: []))
        try await meetingRepository.save(MeetingRecord(event: meetingB, dedupKey: nil, status: .scheduled, sources: []))

        let recordingId = UUID()
        let manifestA = try TestFixtures.recordingManifest(recordingId: recordingId, meetingId: meetingA.id)
        try await recordingRepository.save(RecordingRecord(manifest: manifestA, status: .recording))

        // До каскада: второй save с ДРУГИМ manifest.meetingId у уже существующей
        // строки не меняет колонку.
        let manifestB = try TestFixtures.recordingManifest(recordingId: recordingId, meetingId: meetingB.id)
        try await recordingRepository.save(RecordingRecord(manifest: manifestB, status: .recording))
        var columnValue = try Self.readMeetingIdColumn(recordingId: recordingId, database: temp.database)
        XCTAssertEqual(columnValue, meetingA.id.uuidString, "save на существующей строке не меняет meeting_id")

        // Каскад: удаление meetingA обнуляет колонку.
        try await meetingRepository.delete(meetingIds: [meetingA.id])
        columnValue = try Self.readMeetingIdColumn(recordingId: recordingId, database: temp.database)
        XCTAssertNil(columnValue)

        // После каскада: save с manifest.meetingId, ссылающимся на meetingB
        // (существующую встречу), у уже существующей строки по-прежнему не
        // трогает колонку — она остаётся NULL, а не становится meetingB.id.
        try await recordingRepository.save(RecordingRecord(manifest: manifestB, status: .recording))
        columnValue = try Self.readMeetingIdColumn(recordingId: recordingId, database: temp.database)
        XCTAssertNil(columnValue, "save на осиротевшей строке не восстанавливает meeting_id")

        // Манифест при этом хранит переданное значение — колонка и манифест
        // осознанно расходятся (инвариант 7, вторая половина).
        let stored = try await recordingRepository.recording(id: recordingId)
        XCTAssertEqual(stored?.manifest.meetingId, meetingB.id)
    }

    private static func readMeetingIdColumn(recordingId: UUID, database: StorageDatabase) throws -> String? {
        try database.rawRead { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT meeting_id FROM recordings WHERE id = ?", arguments: [recordingId.uuidString]
            )
            return row?["meeting_id"]
        }
    }

    // MARK: - Снимок каталога побайтно

    private static func snapshot(of directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in contents {
            result[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return result
    }
}
