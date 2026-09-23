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
