//  RecordingDirectoryCreationTests — MEE-440 (находка РП на приёмке composition root,
//  MEE-434, 09:15 UTC): `RecordingRepository.createDirectory(recordingId:)` создаёт
//  `recordings/<uuid>` по `FileLayout`, симметрично `delete(recordingId:deleteFiles:)`
//  (К19, `RecordingRepositoryTests.swift`), и бросает `StorageError.io` при отказе файловой
//  системы — не глотает его `try?`, как раньше делал composition root ad hoc.

import XCTest
import DomainCore
@testable import Storage

final class RecordingDirectoryCreationTests: StorageAsyncTestCase {

    func test_createDirectoryCreatesRecordingsUuidDirectoryOnDisk() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let repository = temp.database.recordingRepository(fileLayout: layout)
        let recordingId = UUID()
        let expectedDirectory = layout.recordingDirectory(recordingId.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedDirectory.path))

        let returned = try await repository.createDirectory(recordingId: recordingId)

        XCTAssertEqual(returned, expectedDirectory)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expectedDirectory.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists)
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// `FileManager.createDirectory(withIntermediateDirectories: true)` не бросает на уже
    /// существующем каталоге (документированное поведение Apple) — второй вызов на том же
    /// `recordingId` обязан пройти без отказа, а не только первый.
    func test_createDirectoryIsIdempotentOnSecondCallForSameRecordingId() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let repository = temp.database.recordingRepository(fileLayout: layout)
        let recordingId = UUID()

        _ = try await repository.createDirectory(recordingId: recordingId)
        let secondReturn = try await repository.createDirectory(recordingId: recordingId)

        XCTAssertEqual(secondReturn, layout.recordingDirectory(recordingId.uuidString))
    }

    /// Предмет постановки: отказ файловой системы обязан быть ВНЯТНЫМ, не проглоченным
    /// `try?`. Вектор — `recordingsRoot()` занят обычным файлом, а не каталогом: попытка
    /// создать под ним подкаталог отказывает на уровне ОС («не каталог»), и это ровно тот
    /// класс отказа (диск/права/занятый путь), которого раньше не было видно.
    func test_createDirectoryThrowsStorageErrorIoInsteadOfSwallowingFailureSilently() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let repository = temp.database.recordingRepository(fileLayout: layout)
        // `recordings` — обычный файл, не каталог: `recordings/<uuid>` не может быть создан
        // ни при каком `recordingId`, потому что его родитель — не каталог.
        try Data("не каталог".utf8).write(to: layout.recordingsRoot())

        do {
            _ = try await repository.createDirectory(recordingId: UUID())
            XCTFail("ожидался StorageError.io — recordingsRoot() занят файлом, не каталогом")
        } catch StorageError.io {
            // ожидаемо — отказ дошёл до вызывающей стороны, а не растворился в `try?`
        }
    }
}
