//  Оснастка тестов модуля calendar-hub — план проверки MEE-361, §1.
//
//  * `FakeWaitSeam` — Ш3. По умолчанию `sleep(for:)` НЕ авторазрешается — висит до
//    `resolveNext()`/`resolveAll()` (режим ворот). Довод — MEE-362, найдено CI (`swift test`
//    красным «коинфлипом» на К1/К2/К7/К10, ни один без зависшего коннектора): `raceTimeout`
//    заводит по ДВЕ дочерних задачи на каждый вызов коннектора — операцию и сон одного и того
//    же шва — и если сон авторазрешается немедленно, обе завершаются «мгновенно», а какая из
//    двух мгновенных задач выиграет гонку `group.next()` — решает планировщик, не тест.
//    Авторазрешение включалось бы монеткой на КАЖДОМ вызове коннектора, не только там, где
//    таймаут — часть проверки. Ворота молчат сами по себе — операция, которой ничто не мешает
//    завершиться, выигрывает гонку всегда; таймаут получает вызывающая сторона явно, отпустив
//    ворота уже ПОСЛЕ того, как коннектор реально встал в `hangOrGate` (см.
//    `resolveTimeoutAfterHang` в `InitializationTests.swift`) — только это доказывает, что
//    отпускаются ворота именно ожидаемой гонки, а не более ранней.
//  * `FakeSecretStore` — Ш1.
//  * `Harness` — актор `CalendarPortImpl` на подставленном мире, с фейковыми коннекторами
//    по числу источников.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import CalendarHub

/// Ограниченный опрос: сон между проверками в цикле до `timeout`, а не без предела —
/// возврат РП (приёмка #85, дефект 7): `resolveTimeoutAfterHang` (`InitializationTests.swift`)
/// висела бы вечно, если бы условие никогда не стало истинным (реальный дефект реализации,
/// не зависший коннектор теста) — тест обязан упасть явно, не полагаться на внешний таймаут CI.
/// `condition` — обычное замыкание, не `@autoclosure`: CI (Swift на раннере) отказывается
/// компилировать `await` внутри асинхронного `@autoclosure` («await in an autoclosure that
/// does not support concurrency») — обычное замыкание с явным `{ ... }` на месте вызова не
/// подвержено этому ограничению. Перевызывается на каждой итерации; допускает побочный
/// эффект (например, `waitSeam.resolveNext()`), тем же приёмом, что было в исходном цикле.
// СТРОКА (бисекция CI-зависания, MEE-362 ч.2): изначально был `await Task.yield()` вместо
// сна — тугой цикл без паузы, который на CPU-ограниченном раннере CI грузит ядро на 100% и
// реально душит СОСЕДНИЕ процессы `swift test --parallel` (у него воркер на цель — отдельный
// процесс ОС), а не только собственный тест: зависание проявлялось в `UnknownKeysTests`,
// файле, не имеющем отношения к CalendarHub, а не в самих К-тестах. `Task.sleep` между
// опросами отдаёт ядро планировщику ОС между проверками вместо злого битья по нему.
func pollUntil(
    timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline {
            XCTFail("опрос не дождался условия за \(timeout)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

final class FakeWaitSeam: WaitSeam, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDurations: [Duration] = []
    private var autoResolve = false
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var durations: [Duration] { locked { recordedDurations } }

    func setAutoResolve(_ value: Bool) { locked { autoResolve = value } }

    /// Ключ на вызов, не плоский список — та же причина, что у `FakeCalendarConnector.
    /// hangOrGate`: отмена ОДНОГО вызова (проигравшая половина гонки, `group.cancelAll()` в
    /// `raceTimeout`) не вправе снять чужое ещё живое ожидание того же шва.
    func sleep(for duration: Duration) async throws {
        locked { recordedDurations.append(duration) }
        guard !locked({ autoResolve }) else { return }
        let key = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyCancelled = locked { () -> Bool in
                    guard !Task.isCancelled else { return true }
                    pending[key] = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let cancelled = locked { pending.removeValue(forKey: key) }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Отпускает один подвешенный вызов; какой именно — не гарантировано (словарь, не
    /// очередь). Возвращает, было ли что отпускать — так вызывающая сторона может ждать
    /// (повторяя вызов), пока нужное ожидание реально не встанет в `pending`.
    @discardableResult
    func resolveNext() -> Bool {
        let entry = locked { () -> CheckedContinuation<Void, Error>? in
            guard let key = pending.keys.first else { return nil }
            return pending.removeValue(forKey: key)
        }
        entry?.resume()
        return entry != nil
    }

    func resolveAll() {
        let waiting = locked { () -> [CheckedContinuation<Void, Error>] in
            let list = Array(pending.values)
            pending.removeAll()
            return list
        }
        for continuation in waiting { continuation.resume() }
    }
}

final class FakeSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [String: String]] = [:]
    private var calls: [(key: String, namespace: String)] = []

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var recordedCalls: [(key: String, namespace: String)] { locked { calls } }

    func get(key: String, namespace: String) async throws -> String? {
        locked {
            calls.append((key, namespace))
            return storage[namespace]?[key]
        }
    }

    func set(key: String, value: String?, namespace: String) async throws {
        locked {
            calls.append((key, namespace))
            if let value {
                storage[namespace, default: [:]][key] = value
            } else {
                storage[namespace]?[key] = nil
            }
        }
    }
}

// СТРОКА (бисекция CI-зависания, MEE-362 ч.2, временно): CI-обёртчик буферизует stdout
// самого `swift test` крупными пачками (видно по группам строк с ОДНИМ и тем же
// временем в логе) — при убийстве по таймауту последняя пачка не флашится и пропадает
// целиком, поэтому реальная точка зависания невидна ни в одном прогоне. `FileHandle.
// standardError.write` — сырой `write()` в fd, идёт мимо буфера stdio; шаг CI сам
// собирает и stdout, и stderr в один и тот же файл (`2>&1`), так что эти строки
// долетают в лог даже при принудительном убийстве. Снять после того, как зависание
// найдено — диагностика, не постоянная часть тестов.
// СТРОКА (то же зависание, следующий заход): `XCTestObservationCenter.addTestObserver`
// на macOS требует главного потока — вызов из тела `async`-теста (не на главном потоке)
// рушил процесс на месте (`NSInternalInconsistencyException`), а не помогал диагностике.
// `checkpoint(_:)` — просто сырая запись в stderr, без регистрации наблюдателя нигде;
// вызывается вручную с именем теста как первая строка каждого метода.
enum HangDiagnostics {
    static func checkpoint(_ label: String) {
        FileHandle.standardError.write(Data("[HANG-DIAG] \(label)\n".utf8))
    }
}

struct Harness {
    let connectorRepository = InMemoryConnectorRepository()
    let meetingRepository = InMemoryMeetingRepository()
    let waitSeam = FakeWaitSeam()
    let secretStore = FakeSecretStore()
    let connectors: [String: FakeCalendarConnector]
    let hub: CalendarPortImpl

    init(sourceIds: [String]) {
        var connectorMap: [CalendarSourceId: CalendarConnector] = [:]
        var fakes: [String: FakeCalendarConnector] = [:]
        for id in sourceIds {
            let fake = FakeCalendarConnector()
            connectorMap[CalendarSourceId(rawValue: id)] = fake
            fakes[id] = fake
        }
        connectors = fakes
        hub = CalendarPortImpl(
            connectorRepository: connectorRepository, meetingRepository: meetingRepository,
            waitSeam: waitSeam, secretStore: secretStore, connectors: connectorMap
        )
    }

    func connector(_ id: String) -> FakeCalendarConnector {
        guard let connector = connectors[id] else { preconditionFailure("нет фейка на источник \(id)") }
        return connector
    }

    static func record(
        id: String, cursor: String? = nil, selectedCalendarIds: [String] = [], lastSyncAt: Date? = nil
    ) -> ConnectorRecord {
        ConnectorRecord(
            id: id, type: "fake", pluginId: nil, settingsJson: Data("{}".utf8), keychainNamespace: id,
            selectedCalendarIds: selectedCalendarIds, isEnabled: true, lastSyncAt: lastSyncAt,
            cursor: cursor, lastError: nil
        )
    }
}

/// Флаг завершения задачи, читаемый из другого Task без гонки данных (К66/К75) — актор
/// проще замка для одного булева поля, разделяемого несколькими файлами теста.
actor DoneFlag {
    private var done = false
    func markDone() { done = true }
    func isDone() -> Bool { done }
}
