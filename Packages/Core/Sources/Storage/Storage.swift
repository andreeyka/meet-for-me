//  Storage — модуль хранилища, C-010 (MEE-18) v7.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  Каталог принадлежит владельцу модуля: файлы здесь изменяет только он (П1).
//  Всё, что пересекает границу модуля, описано контрактом C-010 и меняется
//  только через interface-request (П2, П6). Границы и запреты — docs/module-map.md.
//
//  ЗАДАЧА: MEE-324, часть 1 — схема, миграция v1-slice1, MeetingRepository,
//  RecordingRepository. Остальные шесть репозиториев (Person, Transcript,
//  SpeakerProfile, Connector, MeetingOutput, Settings) и JobRepository — предмет
//  следующих частей той же задачи (постановка МЕЕ-324, «Развилки», разбиение на
//  части — решение исполнителя).
//
//  Файл держит только точку входа модуля; схема — `Migrations.swift`, отображение
//  ошибок — `StorageErrorMapping.swift`, реализации репозиториев — отдельные файлы
//  по одному на порт.

import Foundation
import GRDB
import DomainCore

/// Единственная публичная точка входа модуля: открывает файл базы, применяет
/// миграцию `v1-slice1` и раздаёт реализации портов `DomainCore`.
///
/// Публичный тип модуля (C-010 инв. 19, вектор 2 — К25): без него создать
/// реализацию портов снаружи нечем, поскольку связывание идёт в composition
/// root (C-016), а сам `DatabasePool` наружу не проходит (инв. 19, вектор 1).
public final class StorageDatabase: Sendable {

    let dbPool: DatabasePool

    /// - Parameter path: путь к файлу базы (`FileLayout.databaseURL()`, C-010 §1).
    ///   Каталог, в котором лежит файл, обязан существовать — модуль его не создаёт.
    public init(path: URL) throws {
        var configuration = Configuration()
        // Инв. 1 и 2: PRAGMA — на КАЖДОМ соединении, которое открывает `storage`.
        // `prepareDatabase` — единственный крюк GRDB, исполняемый на всяком новом
        // соединении пула, писательском и читательских одинаково (Ш6).
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            // `journal_mode = wal` не повторяется здесь: он написан в заголовок
            // файла базы и наследуется всяким новым соединением того же файла
            // (см. ниже, установка при первом открытии). `synchronous`, напротив, —
            // сессионная настройка SQLite и обязана переустанавливаться на каждом
            // соединении отдельно.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: path.path, configuration: configuration)
        } catch {
            throw StorageError.io(message: String(describing: error))
        }
        self.dbPool = pool

        do {
            // WAL — один раз на файл, до первого чтения любым репозиторием (§3, §4).
            try dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
        } catch {
            throw StorageError.io(message: String(describing: error))
        }

        do {
            try StorageMigrations.migrator.migrate(dbPool)
        } catch let error as StorageError {
            throw error
        } catch let error as DatabaseError {
            throw StorageError.migrationFailed(identifier: "v1-slice1", message: error.description)
        } catch {
            throw StorageError.migrationFailed(identifier: "v1-slice1", message: String(describing: error))
        }
    }

    // MARK: - Репозитории (§5)

    public func meetingRepository() -> MeetingRepository {
        GRDBMeetingRepository(database: self)
    }

    public func recordingRepository(fileLayout: FileLayout) -> RecordingRepository {
        GRDBRecordingRepository(database: self, fileLayout: fileLayout)
    }
}
