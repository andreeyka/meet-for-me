//  TestSeams — швы Ш6 и Ш7 перечня MEE-189 §0.5.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  Точки НЕ публичны (`internal`): вынос их в `public` нарушил бы инвариант 19
//  C-010 ровно тем, ради чего шов заводится (перечень, Ш7, «Граница»). Доступны
//  тесту через `@testable import Storage`.
//
//  Ш6 — наблюдение соединений пула: сколько читателей открыто и что видно на
//  каждом PRAGMA-запросом (инварианты 1, 2).
//  Ш7 — прямой SQL мимо репозитория: вставка недостижимой обычным API строки
//  и сверка колонок запросом.

import Foundation
import GRDB

/// Снимок трёх PRAGMA на одном соединении пула (Ш6).
struct PoolConnectionPragmas: Equatable {
    let foreignKeys: Int64
    let journalMode: String
    let synchronous: Int64
}

extension StorageDatabase {

    /// Ш7: произвольная запись мимо репозитория, на той же базе, что видят репозитории.
    func rawWrite<T>(_ body: (Database) throws -> T) throws -> T {
        try dbPool.write(body)
    }

    /// Ш7: произвольное чтение мимо репозитория.
    func rawRead<T>(_ body: (Database) throws -> T) throws -> T {
        try dbPool.read(body)
    }

    /// Ш6: открывает ровно `readerCount` читательских соединений ОДНОВРЕМЕННО плюс
    /// писательское и снимает три PRAGMA на каждом. Соединения удерживаются открытыми,
    /// пока не собраны данные со всех, — иначе пул переиспользовал бы одно соединение
    /// последовательно, и число опрошенных не отличалось бы от единицы (Ш6, основание).
    func poolConnectionPragmas(readerCount: Int) throws -> [PoolConnectionPragmas] {
        func snapshot(_ db: Database) throws -> PoolConnectionPragmas {
            PoolConnectionPragmas(
                foreignKeys: try Int64.fetchOne(db, sql: "PRAGMA foreign_keys") ?? -1,
                journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                synchronous: try Int64.fetchOne(db, sql: "PRAGMA synchronous") ?? -1
            )
        }

        var results: [PoolConnectionPragmas] = []
        try dbPool.writeWithoutTransaction { db in
            results.append(try snapshot(db))
        }

        guard readerCount > 0 else { return results }

        let collector = PoolSeamCollector()
        let startedGate = DispatchSemaphore(value: 0)
        let releaseGate = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for _ in 0..<readerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [dbPool] in
                defer { group.leave() }
                do {
                    try dbPool.read { db in
                        let value = try snapshot(db)
                        collector.append(value)
                        startedGate.signal()
                        releaseGate.wait()
                    }
                } catch {
                    collector.fail(error)
                    startedGate.signal()
                }
            }
        }
        for _ in 0..<readerCount { startedGate.wait() }
        for _ in 0..<readerCount { releaseGate.signal() }
        group.wait()

        if let error = collector.error { throw error }
        results.append(contentsOf: collector.values)
        return results
    }
}

/// Собирает результаты читательских соединений Ш6 с разных потоков.
private final class PoolSeamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [PoolConnectionPragmas] = []
    private var storedError: Error?

    var values: [PoolConnectionPragmas] {
        lock.lock(); defer { lock.unlock() }
        return storedValues
    }

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return storedError
    }

    func append(_ value: PoolConnectionPragmas) {
        lock.lock(); defer { lock.unlock() }
        storedValues.append(value)
    }

    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if storedError == nil { storedError = error }
    }
}
