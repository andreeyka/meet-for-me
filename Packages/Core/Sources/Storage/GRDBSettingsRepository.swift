//  GRDBSettingsRepository — реализация `SettingsRepository`, C-010 (MEE-18) v7 §5.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  СТРОКА: `app_settings.value` объявлена `TEXT NOT NULL` в DDL §3, а порт
//  возвращает/принимает `Data?` — контракт не говорит явно, как `nil`
//  представлен в NOT NULL колонке. Решение здесь: `nil` значит «строки нет»,
//  а не «строка с пустым значением» — `setValue(nil, forKey:)` удаляет
//  строку, `value(forKey:)` на отсутствующем ключе отдаёт `nil` (это и так
//  требует инвариант 20/К27 для читающих методов). Ни один критерий этого
//  раздела не различает эти два случая явно. За контракт не решаю.

import Foundation
import GRDB
import DomainCore

final class GRDBSettingsRepository: SettingsRepository {

    private let database: StorageDatabase

    init(database: StorageDatabase) {
        self.database = database
    }

    func value(forKey key: String) async throws -> Data? {
        do {
            return try await database.dbPool.read { db in
                try Data.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: [key])
            }
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.setting, id: key)
        }
    }

    func setValue(_ value: Data?, forKey key: String) async throws {
        do {
            try await database.dbPool.write { db in
                if let value {
                    try db.execute(
                        sql: """
                        INSERT INTO app_settings (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                        arguments: [key, value]
                    )
                } else {
                    try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [key])
                }
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }
}
