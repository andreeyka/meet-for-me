//  StorageTestSupport — общая оснастка тестов, владелец: DEV-2.
//
//  Тесты пишутся против контракта своего модуля, чужие интерфейсы — через фейки
//  из DomainTestKit (П8).
//
//  Базовый класс задаёт `executionTimeAllowance` (жёсткий предел по времени,
//  XCTest) на все async-тесты модуля — постановка МЕЕ-324 требует таймаутов в
//  async-тестах явно.

import XCTest
@testable import Storage

class StorageAsyncTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 30
    }
}

enum StorageTestSupport {

    struct TemporaryDatabase {
        let database: StorageDatabase
        let directory: URL
        let databaseURL: URL
    }

    /// Файл базы во временном каталоге, который тест обязан удалить сам
    /// (`removeItem` в `defer`/`addTeardownBlock`) — `TemporaryFileLayout` из
    /// `DomainTestKit` (К49) не входит в зону этой задачи (DomainTestKit —
    /// «не трогать», постановка МЕЕ-324, «Зона»; фейк — предмет MEE-320).
    static func makeDatabase() throws -> TemporaryDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("db.sqlite")
        let database = try StorageDatabase(path: databaseURL)
        return TemporaryDatabase(database: database, directory: directory, databaseURL: databaseURL)
    }

    static func cleanup(_ temporary: TemporaryDatabase) {
        try? FileManager.default.removeItem(at: temporary.directory)
    }
}
