//  GRDBJobRepository — сборка `Job` из строки `jobs`. Разведено по объёму
//  (`type_body_length`), не по смыслу.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище

import Foundation
import GRDB
import DomainCore

extension GRDBJobRepository {

    /// Для методов, которые на нечитаемой строке обязаны бросать (все, кроме
    /// `jobs(status:)`, К30): строка, у которой не разбирается сам `id`, и строка,
    /// у которой не разбирается что-либо ещё, — оба исхода дают `dataCorrupted`.
    static func job(from row: Row) throws -> Job {
        let idText: String = row["id"]
        guard let id = UUID(uuidString: idText) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.job, id: idText, message: "id не разбирается в UUID"
            )
        }
        return try decodeJob(id: id, row: row)
    }

    /// Разбор всего, кроме `id`, — общая часть `job(from:)` и ветки `jobs(status:)`,
    /// которая ловит эту ошибку отдельно, чтобы назвать строку в `unreadable`.
    static func decodeJob(id: UUID, row: Row) throws -> Job {
        let typeText: String = row["type"]
        guard let type = JobType(rawValue: typeText) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.job, id: id.uuidString, message: "недопустимое значение type"
            )
        }
        let statusText: String = row["status"]
        guard let status = JobStatus(rawValue: statusText) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.job, id: id.uuidString, message: "недопустимое значение status"
            )
        }
        let thermalText: String = row["max_thermal_pressure"]
        guard let maxThermalPressure = ThermalPressure(rawValue: thermalText) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.job, id: id.uuidString,
                message: "недопустимое значение max_thermal_pressure"
            )
        }
        let payloadText: String = row["payload_json"]
        let payload = try StorageJSON.decodeFromText(
            JobPayload.self, from: payloadText, entity: StorageEntity.job, id: id.uuidString
        )
        let leaseExpiresAt: Int64? = row["lease_expires_at"]
        let attemptStartedAt: Int64? = row["attempt_started_at"]
        return Job(
            id: id, type: type, payload: payload, status: status,
            priority: row["priority"], attempts: row["attempts"], maxAttempts: row["max_attempts"],
            runAfter: EpochTime.date(fromSeconds: row["run_after"]),
            conditions: JobConditions(
                requiresACPower: row["requires_ac_power"], forbidWhileRecording: row["forbid_while_recording"],
                maxThermalPressure: maxThermalPressure, requiresProfileReady: row["requires_profile_ready"]
            ),
            dedupKey: row["dedup_key"],
            leaseExpiresAt: leaseExpiresAt.map(EpochTime.date(fromSeconds:)),
            attemptStartedAt: attemptStartedAt.map(EpochTime.date(fromSeconds:)),
            lastError: row["last_error"],
            createdAt: EpochTime.date(fromSeconds: row["created_at"]),
            updatedAt: EpochTime.date(fromSeconds: row["updated_at"])
        )
    }

    /// Аргументы `INSERT`/полного `UPDATE` — восемнадцать колонок в порядке DDL §3
    /// C-010, как обычный массив (а не `StatementArguments`), чтобы вызывающая
    /// сторона могла дописать хвост (`WHERE id = ?`) обычной конкатенацией `Array`.
    static func arguments(for job: Job) throws -> [DatabaseValueConvertible?] {
        let payloadText = try StorageJSON.encodeToText(job.payload)
        return [
            job.id.uuidString, job.type.rawValue, payloadText, job.status.rawValue,
            job.priority, job.attempts, job.maxAttempts, EpochTime.seconds(job.runAfter),
            job.conditions.requiresACPower, job.conditions.forbidWhileRecording,
            job.conditions.maxThermalPressure.rawValue, job.conditions.requiresProfileReady,
            job.dedupKey, job.leaseExpiresAt.map(EpochTime.seconds), job.attemptStartedAt.map(EpochTime.seconds),
            job.lastError, EpochTime.seconds(job.createdAt), EpochTime.seconds(job.updatedAt)
        ]
    }
}
