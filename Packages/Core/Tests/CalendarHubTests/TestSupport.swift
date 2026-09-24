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

// СТРОКА (бисекция CI-зависания, MEE-362 ч.2): изначально был `await Task.yield()` вместо
// сна — тугой цикл без паузы, который на CPU-ограниченном раннере CI грузит ядро на 100% и
// реально душит СОСЕДНИЕ процессы `swift test --parallel` (у него воркер на цель — отдельный
// процесс ОС), а не только собственный тест: зависание проявлялось в `UnknownKeysTests`,
// файле, не имеющем отношения к CalendarHub, а не в самих К-тестах. `Task.sleep` между
// опросами отдаёт ядро планировщику ОС между проверками вместо злого битья по нему.
/// Ограниченный опрос: сон между проверками в цикле до `timeout`, а не без предела —
/// возврат РП (приёмка #85, дефект 7): `resolveTimeoutAfterHang` (`InitializationTests.swift`)
/// висела бы вечно, если бы условие никогда не стало истинным (реальный дефект реализации,
/// не зависший коннектор теста) — тест обязан упасть явно, не полагаться на внешний таймаут CI.
/// `condition` — обычное замыкание, не `@autoclosure`: CI (Swift на раннере) отказывается
/// компилировать `await` внутри асинхронного `@autoclosure` («await in an autoclosure that
/// does not support concurrency») — обычное замыкание с явным `{ ... }` на месте вызова не
/// подвержено этому ограничению. Перевызывается на каждой итерации; допускает побочный
/// эффект (например, `waitSeam.resolveNext()`), тем же приёмом, что было в исходном цикле.
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

/// Обёртка над `AsyncStream.Iterator` для гонки с таймаутом в `nextOrTimeout` (возврат РП,
/// приёмка #94, п. 5) — actor, не `inout`: `next()` мутирует структуру-итератор, а
/// `TaskGroup.addTask` не умеет захватывать `inout`-параметр из внешней области.
actor StreamIteratorBox<Element: Sendable> {
    private var iterator: AsyncStream<Element>.Iterator
    init(_ stream: AsyncStream<Element>) { iterator = stream.makeAsyncIterator() }

    /// Не `await iterator.next()` напрямую: `next()` — `mutating`, и Swift не даёт звать
    /// mutating async метод через actor-isolated свойство (компилятор CI, найдено #94 —
    /// «cannot call mutating async function on actor-isolated property»). Локальная копия —
    /// стандартный обход для actor-isolated `AsyncIteratorProtocol`.
    func next() async -> Element? {
        var localIterator = iterator
        let value = await localIterator.next()
        iterator = localIterator
        return value
    }
}

private enum RaceOutcome<Element: Sendable>: Sendable {
    case value(Element?)
    case timedOut
}

/// Ограниченное ожидание следующего элемента потока (К62/К63, `ChangesStreamTests.swift`) —
/// тот же довод, что у `pollUntil` (дефект 7, приёмка #85): тест обязан упасть явно, не
/// зависнуть навечно, если поток не публикует ожидаемое. Отмена проигравшей ветки безопасна:
/// `AsyncStream.Iterator.next()` документированно отдаёт `nil` сразу же, как только вызывающая
/// его задача отменена, — элемент при этом не теряется, следующий вызов `box.next()` увидит
/// его как обычно.
func nextOrTimeout<Element: Sendable>(
    _ box: StreamIteratorBox<Element>, timeout: Duration = .seconds(10),
    file: StaticString = #filePath, line: UInt = #line
) async -> Element? {
    let outcome = await withTaskGroup(of: RaceOutcome<Element>.self) { group -> RaceOutcome<Element> in
        group.addTask { .value(await box.next()) }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return .timedOut
        }
        let first = await group.next() ?? .timedOut
        group.cancelAll()
        return first
    }
    switch outcome {
    case .value(let element):
        return element
    case .timedOut:
        XCTFail("следующий элемент потока не пришёл за \(timeout)", file: file, line: line)
        return nil
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

    /// К66/К75 (fan-out по нескольким источникам): сеет записи, инициализирует каждый
    /// источник через listCalendars() — общий пролог, вынесенный из обоих тестов, чтобы
    /// не раздувать их тела сверх function_body_length.
    func seedAndInitialize(_ ids: [String]) async throws -> [FakeCalendarConnector] {
        connectorRepository.seed(ids.map { Harness.record(id: $0) })
        let fakes = ids.map { connector($0) }
        for (index, fake) in fakes.enumerated() {
            fake.setInitializeResult(capabilities: ConnectorCapabilities(
                deltaSync: false, push: false, attendees: true, conference: true, auth: .none
            ))
            fake.setListCalendars([])
            _ = try await hub.listCalendars(source: CalendarSourceId(rawValue: ids[index]))
        }
        return fakes
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

    /// Харнесс с записями уже заведёнными и `initialize` каждого источника уже настроенным
    /// на заданные `capabilities` — общий пролог `MergeTests.swift`/`MergeCrossCycleTests.swift`
    /// (IR-126, MEE-385), не раздувающий тела тестов сверх `function_body_length` тем же
    /// довеском, каким пятистрочный пролог повторялся бы в каждом (тот же приём, что уже
    /// даёт `seedAndInitialize` выше — здесь только без вызова `listCalendars`, тесты этого
    /// файла его не проверяют).
    static func mergeReady(sourceIds: [String], deltaSync: Bool = false, cursor: String? = nil) -> Harness {
        let harness = Harness(sourceIds: sourceIds)
        harness.connectorRepository.seed(sourceIds.map { Harness.record(id: $0, cursor: cursor) })
        for id in sourceIds {
            harness.connector(id).setInitializeResult(capabilities: ConnectorCapabilities(
                deltaSync: deltaSync, push: false, attendees: true, conference: true, auth: .none
            ))
        }
        return harness
    }
}

/// Флаг завершения задачи, читаемый из другого Task без гонки данных (К66/К75) — актор
/// проще замка для одного булева поля, разделяемого несколькими файлами теста.
actor DoneFlag {
    private var done = false
    func markDone() { done = true }
    func isDone() -> Bool { done }
}

// MARK: - Оснастка IR-126 (MEE-385) — общая на MergeTests.swift и MergeCrossCycleTests.swift
//
// Не `private static` внутри одного класса теста (как было в едином MergeTests.swift до
// возврата РП, приёмка #105): SwiftLint `file_length` считает каждый ФАЙЛ отдельно, и после
// четырёх новых тестов возврата единый файл вышел за лимит — тесты разнесены на два файла
// (тот же приём, что уже стоит у CalendarPortImplSync.swift/CalendarPortImplMerge.swift),
// и общая оснастка встала сюда, а не продублирована в каждом.

/// Payload с общим `icalUid` ("shared-uid") — три источника с одним и тем же `icalUid`
/// сходятся на один дедуп-ключ (C-005 п. 4, признак (а)), не заводят три отдельных встречи.
func mergeTestPayload(
    connectorId: String, externalId: String, lastModified: Date, location: String? = nil,
    attendees: [MeetingEvent.Attendee] = []
) throws -> MeetingEventPayload {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    return try MeetingEventPayload(
        sourceConnectorId: connectorId, externalId: externalId, icalUid: "shared-uid", title: "T",
        start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
        isCancelled: false, organizer: nil, attendees: attendees, location: location, bodyText: nil,
        conference: nil, lastModified: lastModified
    )
}

func mergeTestAttendee(name: String, email: String?) throws -> MeetingEvent.Attendee {
    try MeetingEvent.Attendee(
        person: try MeetingEvent.Person(name: name, email: email), responseStatus: .accepted, isOptional: false
    )
}

/// Счётчик вызовов `MeetingRepository.save(_:)` из общего `PortCallLog` фейка — инв. 11
/// (`test_inv11_secondMergeOfSameMeetingDoesNotStartUntilFirstFinishes`, MergeTests.swift)
/// опрашивает его напрямую, без ожидания конкретного тайминга самого слияния.
func meetingRepositorySaveCallCount(_ repository: InMemoryMeetingRepository) -> Int {
    repository.callLog.calls.filter { $0.signature == "MeetingRepository.save(_:)" }.count
}

/// Сеет мимо `save` встречу с двумя источниками ("A"/`evt-a`, "B"/`evt-b`, общий `icalUid`),
/// оба со снимками, identity и содержимое — B (больший `lastModified`) — общий пролог
/// `test_inv10_sourceFailureInCycleKeepsOtherSourcesSnapshotsIntact` (MergeCrossCycleTests.swift),
/// вынесенный сюда той же причиной, что `mergeReady`: не раздувать тело теста сверх
/// `function_body_length`.
func seedTwoSourceMeetingIdentityB(
    _ harness: Harness, base: Date, locationA: String?, locationB: String?
) throws {
    let payloadA = try mergeTestPayload(connectorId: "A", externalId: "evt-a", lastModified: base, location: locationA)
    let payloadB = try mergeTestPayload(
        connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(1), location: locationB
    )
    let event = try MeetingEvent(
        id: UUID(), sourceConnectorId: "B", externalId: "evt-b", icalUid: "shared-uid", title: "T",
        start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false, isCancelled: false,
        organizer: nil, attendees: [], location: locationB, bodyText: nil, conference: nil,
        lastModified: base.addingTimeInterval(1)
    )
    let sources = [
        MeetingSource(
            sourceConnectorId: "A", externalId: "evt-a", icalUid: "shared-uid", lastModified: base, payload: payloadA
        ),
        MeetingSource(
            sourceConnectorId: "B", externalId: "evt-b", icalUid: "shared-uid",
            lastModified: base.addingTimeInterval(1), payload: payloadB
        )
    ]
    harness.meetingRepository.seed([
        MeetingRecord(event: event, dedupKey: DedupKey.make(from: event), status: .ready, sources: sources)
    ])
}

/// Сеет мимо `save` встречу с двумя источниками БЕЗ снимков (`MeetingSource.payload == nil`
/// у обоих) — `test_inv10_identityRecomputedWhenDepartedSourceWasIdentity` (MergeTests.swift),
/// тот же довод, что у `seedTwoSourceMeetingIdentityB` рядом.
func seedTwoSourceMeetingNoSnapshots(
    _ harness: Harness, eventId: UUID, base: Date
) throws {
    let event = try MeetingEvent(
        id: eventId, sourceConnectorId: "src-1", externalId: "evt-1", icalUid: nil, title: "Original",
        start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
        isCancelled: false, organizer: nil, attendees: [], location: nil, bodyText: nil,
        conference: nil, lastModified: base
    )
    let sources = [
        MeetingSource(sourceConnectorId: "src-1", externalId: "evt-1", icalUid: nil, lastModified: base),
        MeetingSource(
            sourceConnectorId: "src-2", externalId: "evt-2", icalUid: nil, lastModified: base.addingTimeInterval(60)
        )
    ]
    harness.meetingRepository.seed([MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: sources)])
}
