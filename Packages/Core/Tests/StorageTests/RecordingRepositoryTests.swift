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

    // MARK: - К88 (инвариант 7, издание v8, IR-113): save пишет meeting_id только при вставке

    /// Вектор без удаления встречи: второй `save` на уже существующей строке
    /// с ДРУГИМ `manifest.meetingId` (включая `nil`) не меняет колонку — она
    /// остаётся тем, что записал `INSERT`, независимо от того, что несёт
    /// `manifest.meetingId` при повторном вызове.
    func testK88_secondSaveWithDifferentMeetingIdDoesNotChangeColumnWithoutDeletion() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let meetingRepository = temp.database.meetingRepository()

        let meetingA = try TestFixtures.meetingEvent(externalId: "ext-k88-a")
        let meetingB = try TestFixtures.meetingEvent(externalId: "ext-k88-b")
        try await meetingRepository.save(MeetingRecord(event: meetingA, dedupKey: nil, status: .scheduled, sources: []))
        try await meetingRepository.save(MeetingRecord(event: meetingB, dedupKey: nil, status: .scheduled, sources: []))

        // (a) второе значение — существующая, но ДРУГАЯ встреча.
        let recordingToOther = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingToOther, meetingId: meetingA.id),
            status: .recording
        ))
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingToOther, meetingId: meetingB.id),
            status: .recording
        ))
        let columnToOther = try Self.readMeetingIdColumn(recordingId: recordingToOther, database: temp.database)
        XCTAssertEqual(columnToOther, meetingA.id.uuidString, "save на существующей строке не меняет meeting_id")

        // (b) второе значение — nil.
        let recordingToNil = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingToNil, meetingId: meetingA.id),
            status: .recording
        ))
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingToNil, meetingId: nil),
            status: .recording
        ))
        let columnToNil = try Self.readMeetingIdColumn(recordingId: recordingToNil, database: temp.database)
        XCTAssertEqual(
            columnToNil, meetingA.id.uuidString, "save на существующей строке не меняет meeting_id даже на nil"
        )
    }

    /// Вектор с удалённой встречей (C-018 v8 §10, восстановление осиротевшей
    /// каскадом записи): каскад успевает обнулить колонку ДО второго вызова
    /// `save`. Второй вызов передаёт `manifest.meetingId`, равный уже
    /// удалённой встрече, — реализация, переписывающая колонку из манифеста
    /// при каждом `save`, попыталась бы записать в неё несуществующий
    /// `meeting_id` и бросила бы на внешнем ключе; правильная реализация не
    /// трогает уже осиротевшую колонку и проходит без ошибки.
    func testK88_secondSaveAfterMeetingDeletedDoesNotRestoreColumnAndDoesNotThrowForeignKey() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let meetingRepository = temp.database.meetingRepository()

        let meetingA = try TestFixtures.meetingEvent(externalId: "ext-k88-deleted")
        try await meetingRepository.save(MeetingRecord(event: meetingA, dedupKey: nil, status: .scheduled, sources: []))

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId, meetingId: meetingA.id),
            status: .recording
        ))
        try await meetingRepository.delete(meetingIds: [meetingA.id])
        let afterCascade = try Self.readMeetingIdColumn(recordingId: recordingId, database: temp.database)
        XCTAssertNil(afterCascade, "каскад обнулил колонку до второго save")

        // Второй save несёт meetingId уже удалённой встречи — не должен
        // ни восстановить колонку, ни бросить на внешнем ключе.
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId, meetingId: meetingA.id),
            status: .recording
        ))
        let afterSecondSave = try Self.readMeetingIdColumn(recordingId: recordingId, database: temp.database)
        XCTAssertNil(afterSecondSave, "save на осиротевшей строке не восстанавливает meeting_id и не бросает")

        // Манифест при этом хранит переданное значение — колонка и манифест
        // осознанно расходятся (инвариант 7, вторая половина, К87).
        let stored = try await recordingRepository.recording(id: recordingId)
        XCTAssertEqual(stored?.manifest.meetingId, meetingA.id)
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
