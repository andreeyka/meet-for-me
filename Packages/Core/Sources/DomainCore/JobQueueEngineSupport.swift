//  Переходы состояния `Job`, общие для нескольких файлов реализации очереди (C-013 v8),
//  и `ThermalPressure: Comparable` — сравнение нужно ровно одному месту, готовности к
//  запуску (инвариант 4: «не превышен maxThermalPressure»), и нигде в дереве до этой
//  задачи не было объявлено (по тому же доводу и тем же приёмом, что `MinChip` в
//  `ModelCatalogPort.swift`: порядок объявления case — это и есть отношение «горячее»).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Все переходы здесь — internal: они не часть публичной поверхности контракта, только
//  устройство реализации, разрешённое ей свободно менять форму `Job` внутри модуля.

import Foundation

/// Задача, реально исполняемая обработчиком, вместе с типом — считать предел `maxConcurrent`
/// (§4) без обращения к репозиторию. Тип, а не кортеж: `large_tuple` разрешает два члена.
struct RunningEntry: Sendable {
    let type: JobType
    let task: Task<Void, Never>
}

extension ThermalPressure: Comparable {
    /// `Equatable` уже даёт перечисление с `String`-значением (`PowerSnapshot: Equatable`
    /// в `PowerPort.swift` уже несёт `ThermalPressure` полем и компилируется — второй раз
    /// объявлять `==` здесь не нужно и было бы двойным объявлением). `Comparable` его не
    /// наследует: `<` пишется всегда вручную, тем же приёмом, что `MinChip` в
    /// `ModelCatalogPort.swift` — порядок case, а не алфавит raw value.
    private var ordinal: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

extension Job {

    /// §7, шаг 5: взятый кандидат не прошёл условие — прежний `attempts`, нетронутый
    /// `lastError`, снятый лизинг; `attemptStartedAt` был и остаётся `nil` (попытка не
    /// начиналась). Тем же переходом `stop()` (инвариант 12) возвращает кандидата,
    /// взятого пересмотром и не переданного обработчику.
    func returningUnstartedCandidate(updatedAt now: Date) -> Job {
        Job(
            id: id, type: type, payload: payload, status: .pending, priority: priority,
            attempts: attempts, maxAttempts: maxAttempts, runAfter: runAfter, conditions: conditions,
            dedupKey: dedupKey, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: lastError,
            createdAt: createdAt, updatedAt: now
        )
    }

    /// §7, шаг 4: все условия выполнены — отметка начала попытки ставится непосредственно
    /// перед вызовом `JobHandler.run`, одной записью (инвариант 34), лизинг продлевается.
    func startingAttempt(now: Date, leaseSeconds: Int) -> Job {
        Job(
            id: id, type: type, payload: payload, status: .running, priority: priority,
            attempts: attempts, maxAttempts: maxAttempts, runAfter: runAfter, conditions: conditions,
            dedupKey: dedupKey, leaseExpiresAt: now.addingTimeInterval(Double(leaseSeconds)),
            attemptStartedAt: now, lastError: lastError, createdAt: createdAt, updatedAt: now
        )
    }

    /// Лизинг продлён без изменения прочих полей — исполняемая задача продлевает его не
    /// реже чем раз в 30 секунд (инвариант 11 / К62).
    func renewingLease(now: Date, leaseSeconds: Int) -> Job {
        Job(
            id: id, type: type, payload: payload, status: status, priority: priority,
            attempts: attempts, maxAttempts: maxAttempts, runAfter: runAfter, conditions: conditions,
            dedupKey: dedupKey, leaseExpiresAt: now.addingTimeInterval(Double(leaseSeconds)),
            attemptStartedAt: attemptStartedAt, lastError: lastError, createdAt: createdAt, updatedAt: now
        )
    }

    /// Исход `.success`: `attempts` растёт на фактическое исполнение (инвариант 6), отметка
    /// и лизинг снимаются (инвариант 34).
    func succeeding(now: Date) -> Job {
        Job(
            id: id, type: type, payload: payload, status: .succeeded, priority: priority,
            attempts: attempts + 1, maxAttempts: maxAttempts, runAfter: runAfter, conditions: conditions,
            dedupKey: dedupKey, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: lastError,
            createdAt: createdAt, updatedAt: now
        )
    }

    /// `cancel` для `running`: `Task` обработчика отменена, он вернулся — исполнение
    /// фактическое (инвариант 6), статус `cancelled` после возврата, а не до (инвариант 8).
    func cancelling(now: Date) -> Job {
        Job(
            id: id, type: type, payload: payload, status: .cancelled, priority: priority,
            attempts: attempts + 1, maxAttempts: maxAttempts, runAfter: runAfter, conditions: conditions,
            dedupKey: dedupKey, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: lastError,
            createdAt: createdAt, updatedAt: now
        )
    }

    /// `cancel` для `pending`: немедленно `cancelled`, попытка не расходуется — она не
    /// исполнялась ни секунды.
    func cancellingWithoutExecution(now: Date) -> Job {
        Job(
            id: id, type: type, payload: payload, status: .cancelled, priority: priority,
            attempts: attempts, maxAttempts: maxAttempts, runAfter: runAfter, conditions: conditions,
            dedupKey: dedupKey, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: lastError,
            createdAt: createdAt, updatedAt: now
        )
    }

    /// §5 дословно, развилка «`failed` или `pending` с задержкой» — общая для исхода
    /// `.retry(after:)` (`explicitDelaySeconds` несёт `d`) и для восстановления по
    /// инвариантам 10/11, у которого исхода нет (`explicitDelaySeconds == nil`, значит
    /// формула отката). `attempts` уже посчитан фактическим исполнением ДО вызова
    /// (инвариант 6) — эта функция принимает готовое `attemptsNew`, а не считает его сама,
    /// потому что вызывающая сторона различается: у `.retry` исполнение было прямо сейчас, у
    /// восстановления — было в прошлой, прерванной попытке (§5, «Прерванная попытка»).
    func afterConsumedAttempt(
        attemptsNew: Int, lastError: String, now: Date, explicitDelaySeconds: Double?
    ) -> Job {
        guard attemptsNew < maxAttempts else {
            return Job(
                id: id, type: type, payload: payload, status: .failed, priority: priority,
                attempts: attemptsNew, maxAttempts: maxAttempts, runAfter: runAfter, conditions: conditions,
                dedupKey: dedupKey, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: lastError,
                createdAt: createdAt, updatedAt: now
            )
        }
        let delay = explicitDelaySeconds ?? min(30 * pow(2.0, Double(attemptsNew - 1)), 1800)
        return Job(
            id: id, type: type, payload: payload, status: .pending, priority: priority,
            attempts: attemptsNew, maxAttempts: maxAttempts, runAfter: now.addingTimeInterval(delay),
            conditions: conditions, dedupKey: dedupKey, leaseExpiresAt: nil, attemptStartedAt: nil,
            lastError: lastError, createdAt: createdAt, updatedAt: now
        )
    }

    /// Исход `.permanentFailure`: `failed` немедленно, не дожидаясь `maxAttempts`
    /// (инвариант 7 / К60), но `attempts` всё равно растёт на фактическое исполнение.
    func permanentlyFailing(attemptsNew: Int, lastError: String, now: Date) -> Job {
        Job(
            id: id, type: type, payload: payload, status: .failed, priority: priority,
            attempts: attemptsNew, maxAttempts: maxAttempts, runAfter: runAfter, conditions: conditions,
            dedupKey: dedupKey, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: lastError,
            createdAt: createdAt, updatedAt: now
        )
    }
}
