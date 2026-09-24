//  GRDBJobRepository — реализация `JobRepository`, C-010 (MEE-18) v8 §5
//  и C-013 (MEE-21) v7 §3.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  Тело разведено по объёму на три файла, не по смыслу (тот же приём, что у
//  `GRDBMeetingRepository`/`GRDBTranscriptRepository`): здесь — точечное чтение
//  (`job(id:)`, `jobs(status:)`, `activeJob(dedupKey:)`, `reclaimExpiredLeases(now:)`),
//  запись — `…Write.swift`, сборка строки — `…Mapping.swift`.
//
//  `reclaimExpiredLeases(now:)` — по C-013 v7 (IR-111, МЕЕ-323): отдаёт строки как
//  есть, не ветвясь по `attemptStartedAt` и не переписывая ни одной колонки. Кто
//  считает `attempts + 1`/переход в `failed` по инвариантам 10/11 C-013 — решает
//  очередь отдельными вызовами `update(_ job:)`; это решение архитектора, не вилка
//  исполнителя (в отличие от временной пометки, которую по тому же вопросу нёс
//  `DomainTestKit.InMemoryJobRepository` до правки МЕЕ-328).

import Foundation
import GRDB
import DomainCore

final class GRDBJobRepository: JobRepository {

    private let database: StorageDatabase

    init(database: StorageDatabase) {
        self.database = database
    }

    func job(id: UUID) async throws -> Job? {
        try await withDatabase(id: id.uuidString) { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id.uuidString])
            else { return nil }
            return try Self.job(from: row)
        }
    }

    /// Единственный метод порта, который на нечитаемой строке не бросает (кроме
    /// строки, у которой не разбирается сам `id`, — назвать её нечем, К36).
    func jobs(status: JobStatus) async throws -> JobListing {
        try await withDatabase(id: "?") { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM jobs WHERE status = ?", arguments: [status.rawValue]
            )
            var jobs: [Job] = []
            var unreadable: [UnreadableJobRow] = []
            for row in rows {
                let idText: String = row["id"]
                guard let id = UUID(uuidString: idText) else {
                    throw StorageError.dataCorrupted(
                        entity: StorageEntity.job, id: idText, message: "id не разбирается в UUID"
                    )
                }
                do {
                    jobs.append(try Self.decodeJob(id: id, row: row))
                } catch let error as StorageError {
                    guard case .dataCorrupted(_, _, let message) = error else { throw error }
                    unreadable.append(UnreadableJobRow(id: id, message: message))
                }
            }
            return JobListing(jobs: jobs, unreadable: unreadable)
        }
    }

    func activeJob(dedupKey: String) async throws -> Job? {
        try await withDatabase(id: dedupKey) { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM jobs WHERE dedup_key = ? AND status IN ('pending', 'running') LIMIT 1",
                arguments: [dedupKey]
            ) else { return nil }
            return try Self.job(from: row)
        }
    }

    /// C-013 v7 (IR-111): возвращает строки как есть — ни `status`, ни `attempts`,
    /// ни `attempt_started_at` этим методом не переписываются.
    func reclaimExpiredLeases(now: Date) async throws -> [Job] {
        try await withDatabase(id: "?") { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM jobs WHERE status = 'running' AND lease_expires_at <= ?",
                arguments: [EpochTime.seconds(now)]
            )
            return try rows.map { try Self.job(from: $0) }
        }
    }

    // MARK: - Оснастка, общая для файлов расширений

    func withDatabase<T>(id: String, _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await database.dbPool.read(body)
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.job, id: id)
        }
    }

    var dbPool: DatabasePool { database.dbPool }
}
