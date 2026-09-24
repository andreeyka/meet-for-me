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
