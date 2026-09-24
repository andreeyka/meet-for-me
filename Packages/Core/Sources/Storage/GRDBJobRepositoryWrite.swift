//  GRDBJobRepository — запись (`insert`, `update`, `claimNext`, `failUnreadable`).
//  Разведено по объёму (`type_body_length`), не по смыслу.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище

import Foundation
import GRDB
import DomainCore

extension GRDBJobRepository {

    func insert(_ job: Job) async throws {
        do {
            let arguments = StatementArguments(try Self.arguments(for: job))
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO jobs (
                        id, type, payload_json, status, priority, attempts, max_attempts, run_after,
                        requires_ac_power, forbid_while_recording, max_thermal_pressure,
                        requires_profile_ready, dedup_key, lease_expires_at, attempt_started_at,
                        last_error, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: arguments
                )
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    func update(_ job: Job) async throws {
        do {
            let values: [DatabaseValueConvertible?] = try Self.arguments(for: job) + [job.id.uuidString]
            let arguments = StatementArguments(values)
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    UPDATE jobs SET
                        id = ?, type = ?, payload_json = ?, status = ?, priority = ?, attempts = ?,
                        max_attempts = ?, run_after = ?, requires_ac_power = ?, forbid_while_recording = ?,
                        max_thermal_pressure = ?, requires_profile_ready = ?, dedup_key = ?,
                        lease_expires_at = ?, attempt_started_at = ?, last_error = ?, created_at = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: arguments
                )
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    /// Инвариант 3 C-013: порядок выбора — больше `priority`, при равном меньше
    /// `runAfter`, затем меньше `createdAt`, затем меньше `id` лексикографически.
    /// `excluding` не участвует в SQL (К37: множество из тысячи `id` не должно
    /// упираться в `SQLITE_MAX_VARIABLE_NUMBER`) — кандидаты отбираются запросом,
    /// исключение делает Swift по уже прочитанным строкам.
    func claimNext(
        types: [JobType], excluding: Set<UUID>, now: Date, leaseSeconds: Int
    ) async throws -> Job? {
        guard !types.isEmpty else { return nil }
        let typeTexts = types.map(\.rawValue)
        let placeholders = typeTexts.map { _ in "?" }.joined(separator: ", ")
        let selectValues: [DatabaseValueConvertible?] =
            [EpochTime.seconds(now) as DatabaseValueConvertible?] + typeTexts.map { $0 as DatabaseValueConvertible? }
        let selectArguments = StatementArguments(selectValues)
        do {
            return try await dbPool.write { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM jobs WHERE status = 'pending' AND run_after <= ? AND type IN (\(placeholders))
                    ORDER BY priority DESC, run_after ASC, created_at ASC, id ASC
                    """,
                    arguments: selectArguments
                )
                for row in rows {
                    let idText: String = row["id"]
                    guard let id = UUID(uuidString: idText) else {
                        throw StorageError.dataCorrupted(
                            entity: StorageEntity.job, id: idText, message: "id не разбирается в UUID"
                        )
                    }
                    if excluding.contains(id) { continue }
                    let picked = try Self.decodeJob(id: id, row: row)
                    return try Self.claim(picked, now: now, leaseSeconds: leaseSeconds, db: db)
                }
                return nil
            }
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.job, id: "?")
        }
    }

    /// Одна транзакция: `status = running`, лизинг продлён, `attempt_started_at`
    /// снят в `NULL` — К40(i), промежуточного состояния снаружи не видно.
    private static func claim(_ job: Job, now: Date, leaseSeconds: Int, db: Database) throws -> Job {
        let leaseSeconds64 = EpochTime.seconds(now.addingTimeInterval(Double(leaseSeconds)))
        try db.execute(
            sql: "UPDATE jobs SET status = 'running', lease_expires_at = ?, attempt_started_at = NULL WHERE id = ?",
            arguments: [leaseSeconds64, job.id.uuidString]
        )
        return Job(
            id: job.id, type: job.type, payload: job.payload, status: .running,
            priority: job.priority, attempts: job.attempts, maxAttempts: job.maxAttempts,
            runAfter: job.runAfter, conditions: job.conditions, dedupKey: job.dedupKey,
            leaseExpiresAt: EpochTime.date(fromSeconds: leaseSeconds64), attemptStartedAt: nil,
            lastError: job.lastError, createdAt: job.createdAt, updatedAt: job.updatedAt
        )
    }

    /// Не разбирает `payload_json` (единственный метод порта с этим свойством) —
    /// читает только `type`/`status`. Идемпотентна, `attempts` не меняет.
    func failUnreadable(jobId: UUID, message: String, now: Date) async throws -> JobType? {
        do {
            return try await dbPool.write { db -> JobType? in
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT type, status FROM jobs WHERE id = ?", arguments: [jobId.uuidString]
                ) else { return nil }
                let statusText: String = row["status"]
                guard statusText == "pending" || statusText == "running" else { return nil }
                let typeText: String = row["type"]
                guard let type = JobType(rawValue: typeText) else {
                    throw StorageError.dataCorrupted(
                        entity: StorageEntity.job, id: jobId.uuidString, message: "недопустимое значение type"
                    )
                }
                try db.execute(
                    sql: """
                    UPDATE jobs SET status = 'failed', last_error = ?, updated_at = ?, lease_expires_at = NULL
                    WHERE id = ?
                    """,
                    arguments: [message, EpochTime.seconds(now), jobId.uuidString]
                )
                return type
            }
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.job, id: jobId.uuidString)
        }
    }
}
