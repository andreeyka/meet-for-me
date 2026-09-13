//  SnapshotBuilder — сырые записи HAL → `[AudioProcess]`. Шов Ш1: чистая функция без CoreAudio.
//
//  C-009 §1, §4.1; инварианты 10, 15, 19, 20.
//
//  * Инвариант 15: пустая строка, пришедшая от системы, приводится к `nil` в обоих полях.
//    Приводится ровно пустая строка — пробельная сохраняется как есть: контракт говорит о пустом
//    значении, а не о «пустом по смыслу».
//  * Инвариант 20: недоступность ключа ответственного процесса — `nil` в `responsibleBundleId`,
//    а не отказ, не пустая строка и не подстановка `pid`; снимок отдаётся целиком.
//  * «Почему `responsibleBundleId`, а не `responsiblePid`» (§1): разрешение «pid ответственного →
//    bundle id» не ограничено снимком аудиопроцессов — главный процесс браузера звука не отдаёт.

import DomainCore
import Foundation

/// Одна запись, как её отдал HAL, до нормализации.
struct RawProcessRecord: Equatable, Sendable {
    let pid: Int32
    /// Строка `kAudioProcessPropertyBundleID` как есть; `""` у процесса без бандла.
    let bundleId: String?
    /// Ответственный процесс; `nil`, если разрешить его нечем.
    let responsiblePid: Int32?
    let executableName: String
    let isRunningOutput: Bool
    let isRunningInput: Bool
}

/// Снимок до нормализации: записи и отображение «pid → bundle id» для ответственных процессов.
struct RawSnapshot: Equatable, Sendable {
    let records: [RawProcessRecord]
    let bundleIdsByPid: [Int32: String]
}

enum SnapshotBuilder {

    /// Инвариант 15: пустое значение от системы — `nil`.
    static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Снимок аудиопроцессов на момент `observedAt`: по одному элементу на `pid`, по возрастанию.
    ///
    /// Повтор `pid` в сырых записях сводится в один элемент: личность берётся у первой записи,
    /// флаги открытого вывода и входа — объединением, потому что каждый из них есть наблюдение
    /// системы, а не мнение одной записи.
    static func audioProcesses(from snapshot: RawSnapshot, observedAt: Date) -> [AudioProcess] {
        var merged: [Int32: RawProcessRecord] = [:]
        for record in snapshot.records {
            guard let first = merged[record.pid] else {
                merged[record.pid] = record
                continue
            }
            merged[record.pid] = RawProcessRecord(pid: first.pid,
                                                  bundleId: first.bundleId,
                                                  responsiblePid: first.responsiblePid,
                                                  executableName: first.executableName,
                                                  isRunningOutput: first.isRunningOutput || record.isRunningOutput,
                                                  isRunningInput: first.isRunningInput || record.isRunningInput)
        }
        return merged.values.sorted { $0.pid < $1.pid }.map { record in
            AudioProcess(pid: record.pid,
                         bundleId: normalized(record.bundleId),
                         responsibleBundleId: record.responsiblePid.flatMap { normalized(snapshot.bundleIdsByPid[$0]) },
                         executableName: record.executableName,
                         isRunningOutput: record.isRunningOutput,
                         isRunningInput: record.isRunningInput,
                         observedAt: observedAt)
        }
    }

    /// Инвариант 19: ровно те процессы снимка, чей ключ приложения совпал хотя бы с одной строкой
    /// аргумента по §4.1; порядок — по возрастанию `pid`.
    static func processes(_ snapshot: [AudioProcess], matching entries: [String]) -> [AudioProcess] {
        snapshot
            .filter { process in entries.contains { bundleKeyMatches(appKey: process.appKey, entry: $0) } }
            .sorted { $0.pid < $1.pid }
    }
}
