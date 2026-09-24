//  Оснастка тестов `JobQueueEngine` (C-013 v8, MEE-350) — способ И плана MEE-311:
//  `InMemoryJobRepository`, `ManualClock`, `FakeJobHandler` и заглушка `ModelCatalogPort`.

import XCTest
import DomainCore
import DomainTestKit

/// Готовый набор для одного теста: репозиторий, часы, питание и очередь поверх них же.
/// Каждый тест собирает свой набор — состояние между тестами не разделяется никогда.
struct JobQueueTestRig {
    let repository: InMemoryJobRepository
    let clock: ManualClock
    let power: FakePowerPort
    let catalog: StubModelCatalogPort
    let queue: JobQueueEngine

    /// - Parameters:
    ///   - leaseSeconds: по умолчанию мал (нужен К62 — истечение лизинга без реального
    ///     ожидания десятков секунд).
    init(
        leaseSeconds: Int = 40,
        globalConcurrencyLimit: Int = 2,
        perTypeConcurrencyLimit: Int = 1,
        powerSnapshot: PowerSnapshot = .readyDefault
    ) {
        let manualClock = ManualClock()
        let jobRepository = InMemoryJobRepository()
        let powerPort = FakePowerPort(snapshot: powerSnapshot)
        let catalogPort = StubModelCatalogPort()

        repository = jobRepository
        clock = manualClock
        power = powerPort
        catalog = catalogPort
        // Замыкание захватывает локальные `let`, а не свойства `self`: до конца этого
        // инициализатора `self` неполон, а `clock:` у `JobQueueEngine` — `@escaping`.
        queue = JobQueueEngine(
            repository: jobRepository, modelCatalog: catalogPort, powerPort: powerPort,
            clock: { manualClock.now() }, leaseSeconds: leaseSeconds,
            globalConcurrencyLimit: globalConcurrencyLimit, perTypeConcurrencyLimit: perTypeConcurrencyLimit
        )
    }
}

extension PowerSnapshot {
    /// От сети, без нагрева — ни одно из условий `JobConditions` по умолчанию не блокирует.
    static let readyDefault = PowerSnapshot(
        source: .ac, batteryFraction: 1, isLowPowerModeEnabled: false,
        thermalPressure: .nominal, checkedAt: Date(timeIntervalSince1970: 0)
    )

    /// От батареи — блокирует `requiresACPower`.
    static let onBattery = PowerSnapshot(
        source: .battery, batteryFraction: 0.5, isLowPowerModeEnabled: false,
        thermalPressure: .nominal, checkedAt: Date(timeIntervalSince1970: 0)
    )
}

/// Подача с полным контролем полей — таблица §4 здесь не действует, тест задаёт значения
/// сам. Аналог `JobSubmission.standard`, но без её значений по умолчанию.
func makeSubmission(
    payload: JobPayload = .transcode(recordingId: UUID()),
    priority: Int = 0,
    maxAttempts: Int = 3,
    runAfter: Date = Date(timeIntervalSince1970: 0),
    requiresACPower: Bool = false,
    forbidWhileRecording: Bool = false,
    maxThermalPressure: ThermalPressure = .critical,
    requiresProfileReady: String? = nil,
    dedupKey: String? = nil
) -> JobSubmission {
    JobSubmission(
        payload: payload, priority: priority, maxAttempts: maxAttempts, runAfter: runAfter,
        conditions: JobConditions(
            requiresACPower: requiresACPower, forbidWhileRecording: forbidWhileRecording,
            maxThermalPressure: maxThermalPressure, requiresProfileReady: requiresProfileReady
        ),
        dedupKey: dedupKey
    )
}

/// Строка `running`, вставленная напрямую в фейк — без прохода через `submit`/`claimNext` —
/// для векторов восстановления (К61, К70, К71) и лизинга (К62), которым нужна ГОТОВАЯ строка
/// в заданном состоянии, а не построенная очередью с нуля.
func makeRunningRow(
    type: JobType = .transcode,
    attempts: Int = 0,
    maxAttempts: Int = 3,
    attemptStartedAt: Date?,
    leaseExpiresAt: Date?,
    lastError: String? = nil,
    now: Date = Date(timeIntervalSince1970: 0)
) -> Job {
    Job(
        id: UUID(), type: type, payload: .transcode(recordingId: UUID()), status: .running,
        priority: 0, attempts: attempts, maxAttempts: maxAttempts, runAfter: now,
        conditions: JobConditions(
            requiresACPower: false, forbidWhileRecording: false,
            maxThermalPressure: .critical, requiresProfileReady: nil
        ),
        dedupKey: nil, leaseExpiresAt: leaseExpiresAt, attemptStartedAt: attemptStartedAt,
        lastError: lastError, createdAt: now, updatedAt: now
    )
}

/// MEE-377 (аудит, возврат РП на приёмке #93): гонка `iterator.next()` с дедлайном — раньше
/// вызовы `next()` в тестах `JobQueueEngine` (`drainExactly`, К69) шли напрямую, «БЕЗ
/// таймаута нарочно», доводом «счётчик обязан ровно совпадать» (число событий, которое
/// сценарий действительно публикует, а не приблизительная граница). Расхождение
/// (реализация публикует МЕНЬШЕ событий, чем ждёт счётчик) тонуло в таймауте `swift test`
/// (300 с, MEE-329) без единого слова о причине. 10 секунд — с большим запасом сверх любого
/// реального сценария (сравнить нечего: без расхождения событие уже лежит в буфере к моменту
/// вызова, `JobEventBroadcaster.publish` — синхронный `continuation.yield`).
///
/// Гонка — НЕструктурная (голые `Task`, не `TaskGroup`): `withTaskGroup` на выходе сам ждёт
/// каждую дочернюю задачу до конца, и это свело бы дедлайн к тому же ожиданию, которое он
/// призван оборвать, если бы `next()` СИСТЕМАТИЧЕСКИ не отвечал на отмену, — на практике
/// отвечает (см. ниже), но `withTaskGroup` подошёл бы всё равно хуже: гонка через голые
/// `Task` не зависит от этого факта вовсе. Копия `iterator`, переданная в свою `Task`, — тот
/// же `AsyncStream.AsyncIterator`, что и снаружи: обе читают из одного общего буфера потока.
///
/// Обе проигравшие задачи `cancel()`ятся в `defer` — симметрично, не только `timeoutTask`.
/// MEE-378, п. 8 (возврат РП после приёмки #93, поправка находки MEE-375 — см. довод у
/// `deinit` `JobQueueEngine.swift`): `cancel()` штатно завершает `for await`/`next()` над
/// `AsyncStream` (возвращает `nil` по отмене), тем же приёмом, что `Task.sleep` отвечает
/// `throw` на отмену, — прежний текст здесь ошибочно называл это асимметричным и заявлял,
/// что проигравшая `next()`-задача «висит НАВСЕГДА» и может «украсть» будущее событие
/// следующего вызова; это неверно и снято. Настоящей причиной каскада зависаний на приёмке
/// #93 была подписка на `events()` ПОСЛЕ уже случившегося `submit()` (первое событие ушло в
/// пустоту — подписчиков ещё не было), а не что-либо в этом предохранителе. Порядок
/// «подписаться, затем действовать» остаётся обязателен для каждого теста в любом случае —
/// но не из-за этого предохранителя.
func nextOrFail(
    _ iterator: AsyncStream<JobEvent>.AsyncIterator, seconds: UInt64 = 10,
    file: StaticString = #filePath, line: UInt = #line
) async -> JobEvent? {
    let outcome = DrainRaceOutcome()
    let racer = Task {
        var iterator = iterator
        let event = await iterator.next()
        await outcome.resolve(.some(event))
    }
    let timeoutTask = Task {
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        await outcome.resolve(.none)
    }
    defer {
        racer.cancel()
        timeoutTask.cancel()
    }
    guard let event = await outcome.wait() else {
        XCTFail(
            "iterator.next() не вернул событие за \(seconds) с — расхождение числа " +
                "публикуемых событий (аудит MEE-377), а не обычное падение",
            file: file, line: line
        )
        return nil
    }
    return event
}

/// MEE-378 (п. 5, возврат РП после приёмки #93): подтверждает, что в буфере `iterator` не
/// осталось НИ ОДНОГО лишнего события — та же гонка, что `nextOrFail`, но с обратным
/// ожиданием: победа таймера (НИЧЕГО не пришло за окно) — успех этой проверки, победа
/// `next()` — провал, названный самим полученным событием. Окно короче (по умолчанию 200 мс,
/// не 10 секунд `nextOrFail`) — здесь ждут ПОДТВЕРЖДЕНИЯ отсутствия, а не наступления, и
/// после `waitUntilIdle()` любое действительно ожидаемое событие уже в буфере
/// (`JobEventBroadcaster.publish` синхронен) — окно нужно лишь как момент снятия показания,
/// не как подгонка под планировщик. Обе задачи `cancel()`ятся в `defer`, как у `nextOrFail`
/// (см. довод там же про `cancel()` и `AsyncStream`).
func assertNoMoreEvents(
    _ iterator: AsyncStream<JobEvent>.AsyncIterator, milliseconds: UInt64 = 200,
    file: StaticString = #filePath, line: UInt = #line
) async {
    let outcome = DrainRaceOutcome()
    let racer = Task {
        var iterator = iterator
        let event = await iterator.next()
        await outcome.resolve(.some(event))
    }
    let timeoutTask = Task {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        await outcome.resolve(.none)
    }
    defer {
        racer.cancel()
        timeoutTask.cancel()
    }
    if let event = await outcome.wait() {
        XCTFail("буфер не пуст — лишнее событие \(String(describing: event))", file: file, line: line)
    }
}

/// Разрешение гонки `nextOrFail` — первое из двух `resolve` (настоящий `next()` либо
/// дедлайн) побеждает, второе не действует; ждущие `wait()` будятся один раз.
private actor DrainRaceOutcome {
    private var value: JobEvent??
    private var waiters: [CheckedContinuation<JobEvent??, Never>] = []

    func resolve(_ newValue: JobEvent??) {
        guard value == nil else { return }
        value = newValue
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume(returning: newValue)
        }
    }

    func wait() async -> JobEvent?? {
        if value != nil { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
