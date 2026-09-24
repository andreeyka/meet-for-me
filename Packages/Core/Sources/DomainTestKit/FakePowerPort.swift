//  FakePowerPort — реализация `PowerPort` в памяти, C-008 §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Управляется тестом целиком: `PowerSnapshot` задаётся и меняется на лету, в поток `events()`
//  проталкивается ЛЮБОЙ `PowerEvent`, список живых токенов читается вместе с их `reason`
//  и `label`, `end()` убирает из списка ровно свой токен.
//
//  Снимок, который настоящий порт отдать не вправе, проходит здесь НЕИЗМЕНЁННЫМ и не приводится
//  ни к чему. Основание — §«Построение значения на границе модуля» C-008 дословно:
//  «`PowerSnapshot(source: .battery, batteryFraction: 1.5, …)` собирается и равен себе —
//  запрещено его отдать из `snapshot()`, а не построить. Ровно это и делает фейк возможным:
//  тест, проверяющий реакцию `JobQueue` на критический нагрев, обязан собрать снимок сам,
//  а не ждать машины в нужном состоянии». Зажатия `batteryFraction` в `0...1` здесь нет.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА, и граница названа здесь потому, что молчание о ней читается
//  как её отсутствие. Инварианты 2—9 C-008 — идемпотентность `end()`, снятие удержания при
//  освобождении объекта, счёт удержаний, что именно запрещают `.recording` и `.processing`,
//  «`.didWake` не приходит без `.willSleep`», отсутствие повторов события с тем же значением,
//  согласие `snapshot()` с потоком, «`.screensDidSleep` не влечёт `.willSleep`» — обязанности
//  реализатора `permissions`, проверяются его тестами и фейком не проверяются никогда.
//  Последовательность, запрещённую инварианту 6, фейк пропустит: в этом он и нужен.
//
//  Ограничений у фейка нет вовсе: системе он ничего не запрещает и запрещать не может. Список
//  живых токенов есть НАБЛЮДАЕМОСТЬ для потребителя, а не запись о снятом ограничении.
//
//  MEE-290 ДОБАВИЛ СЮДА ДВА СЧЁТЧИКА И ЖУРНАЛ ВЫЗОВОВ, и ни одного ответа это не меняет.
//  Счётчики выдач и снятий токена — условие `О` плана MEE-288 §2: К67 требует «взятых и
//  отпущенных поровну», а по одному `liveActivities` двойное снятие и неснятие одного из двух
//  выглядят одинаково. Журнал — условие `Н` того же §2, где питание C-008 названо наравне с
//  репозиториями C-010, очередью C-013 и захватом C-004; перечисление §6 плана журнала этому
//  фейку не даёт, и расхождение названо в отчёте MEE-290. Текст контракта C-008 не тронут ни
//  символом: раздел «Фейк для тестов» ни счётчиков, ни журнала не называет и не запрещает, а
//  инвариант 10 говорит о публичной поверхности модуля `permissions`, а не `DomainTestKit`.
//
//  Токены держатся СИЛЬНО, и это решение: список живых обязан быть функцией вызовов
//  `beginActivity` и `end()` и только их. Слабая ссылка сделала бы его функцией ещё и момента
//  освобождения объекта, то есть невоспроизводимой; заодно она проверяла бы инвариант 3 —
//  чужую обязанность. Обратная ссылка токена на порт слабая, и цикла удержания поэтому нет.
//
//  `@unchecked Sendable` с замком, а не актор: `PowerPort` объявлен `: Sendable`, а его методы —
//  не `async` целиком (`events()` синхронен), и актором протокол не покрыть.

import Foundation
import DomainCore

/// Токен удержания, выданный фейком. `reason` и `label` неизменяемы, как требует инвариант 5.
public final class FakePowerActivityToken: PowerActivityToken, @unchecked Sendable {

    public let reason: PowerActivityReason
    public let label: String

    private let onEnd: @Sendable () -> Void

    /// Уровень доступа — внутримодульный: токен выдаёт только `FakePowerPort`, снаружи
    /// `DomainTestKit` его не собрать.
    init(reason: PowerActivityReason, label: String, onEnd: @escaping @Sendable () -> Void) {
        self.reason = reason
        self.label = label
        self.onEnd = onEnd
    }

    /// Убирает из списка живых ровно этот токен. Второй вызов списка не меняет: номера в нём
    /// уже нет. Утверждением об идемпотентности порта (инвариант 2) это не является.
    public func end() {
        onEnd()
    }
}

/// Фейк порта питания и сна. Всё поведение задаёт тест.
public final class FakePowerPort: PowerPort, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "PowerPort"

    private let lock = NSLock()
    private let log: PortCallLog
    private var current: PowerSnapshot
    private var continuations: [AsyncStream<PowerEvent>.Continuation] = []
    private var live: [(id: Int, token: FakePowerActivityToken)] = []
    private var nextId = 0
    private var beginCalls = 0
    private var endCalls = 0

    /// - Parameters:
    ///   - snapshot: стартовый снимок; умолчания нет намеренно — «пустого» `PowerSnapshot`
    ///     не существует, и всякое значение здесь есть вход теста, а не решение фейка.
    ///   - log: общий журнал вызовов (условие `Н` плана MEE-288 §2, где питание C-008 названо
    ///     наравне с репозиториями C-010, очередью C-013 и захватом C-004). Не дали — фейк
    ///     заводит свой. Параметр добавлен со значением по умолчанию: ни один существующий
    ///     вызов `FakePowerPort(snapshot:)` от этого не меняется.
    public init(snapshot: PowerSnapshot, log: PortCallLog = PortCallLog()) {
        current = snapshot
        self.log = log
    }

    /// MEE-378, п. 8 (возврат РП после приёмки #93): исправление находки MEE-375 — ПРЕЖНИЙ
    /// довод здесь был неверен. `Task.cancel()` над задачей, стоящей в `for await` над
    /// `AsyncStream`, ЗАВЕРШАЕТ эту итерацию (`next()` возвращает `nil` по отмене) — это
    /// стандартное, документированное поведение `AsyncStream`, а не то, что предполагал
    /// прежний текст («без явного `finish()` не завершает»). `stop()`/`deinit`
    /// `JobQueueEngine` уже зовут `powerEventsTask?.cancel()` и этим корректно останавливают
    /// подписку сами по себе — постоянной утечки `for await` без этого `deinit`, вопреки
    /// прежней формулировке, не было.
    ///
    /// `finishEvents()` здесь остаётся — раз этот фейк уже уходит, эмитировать в него больше
    /// некому, и явно закрыть поток для ЛЮБОГО ещё не отменённого подписчика (окно между
    /// `cancel()` и фактическим разворачиванием отменённой задачи — кооперативное, не
    /// мгновенное) — лишняя, но безвредная подстраховка, а не необходимость.
    deinit {
        finishEvents()
    }

    /// Журнал, в который пишет этот фейк. Тот же объект, что передали в инициализатор.
    public var callLog: PortCallLog { log }

    /// Замок вокруг состояния. Своя обёртка, а не `NSLocking.withLock`: та пришла в Foundation
    /// позже минимальной версии тулчейна, на которой собирается работа CI `Core (Linux)`.
    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    /// Задать или сменить снимок на лету. Значение не приводится ни к чему.
    public func setSnapshot(_ snapshot: PowerSnapshot) {
        locked { current = snapshot }
    }

    /// Протолкнуть событие в поток. Значение уходит туда значением, а не байтами: `PowerEvent`
    /// `Codable` не объявлен вовсе, и пути из байтов у него нет ни одного.
    public func emit(_ event: PowerEvent) {
        let targets = locked { continuations }
        for continuation in targets {
            continuation.yield(event)
        }
    }

    /// Закрыть поток: подписчики досматривают выданное и выходят из цикла.
    public func finishEvents() {
        let targets = locked { () -> [AsyncStream<PowerEvent>.Continuation] in
            let taken = continuations
            continuations = []
            return taken
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    /// Живые токены в порядке выдачи, каждый со своим `reason` и своим `label`.
    public var liveActivities: [PowerActivityToken] {
        locked { () -> [PowerActivityToken] in live.map(\.token) }
    }

    // MARK: - Счётчики выдач и снятий — условие `О` плана MEE-288 §2, нужны К67

    /// Сколько раз позвали `beginActivity(reason:label:)`.
    public var beginActivityCallCount: Int {
        locked { beginCalls }
    }

    /// Сколько раз позвали `end()` НА ВЫДАННЫХ ЭТИМ ФЕЙКОМ ТОКЕНАХ, включая повторные вызовы
    /// на одном и том же токене.
    ///
    /// **Считаются вызовы, а не снятия, и это несущее решение, а не описка.** К67 требует
    /// «взятых и отпущенных поровну», и различить по `liveActivities` двойное снятие одного
    /// токена от неснятия одного из двух нельзя: повторный `end()` списка не меняет, и оба
    /// расклада дают один и тот же пустой либо непустой список. Счёт ВЫЗОВОВ их разводит:
    /// двойное снятие даёт `1` выдачу против `2` снятий, неснятие — `2` против `1`.
    ///
    /// **Граница названа:** равенство счётчиков не означает, что живых токенов не осталось,
    /// а неравенство не есть нарушение инварианта 2 C-008 — идемпотентность `end()`
    /// обязанность порта, и этот счётчик её не проверяет и проверять не вправе.
    public var endActivityCallCount: Int {
        locked { endCalls }
    }

    // MARK: - PowerPort

    public func snapshot() async -> PowerSnapshot {
        log.record(port: Self.portName, method: "snapshot()")
        return locked { current }
    }

    public func events() -> AsyncStream<PowerEvent> {
        log.record(port: Self.portName, method: "events()")
        return AsyncStream { continuation in
            locked { continuations.append(continuation) }
        }
    }

    public func beginActivity(reason: PowerActivityReason, label: String) async -> PowerActivityToken {
        log.record(
            port: Self.portName,
            method: "beginActivity(reason:label:)",
            arguments: [reason.rawValue, label]
        )
        let identifier = locked { () -> Int in
            nextId += 1
            beginCalls += 1
            return nextId
        }
        let token = FakePowerActivityToken(reason: reason, label: label) { [weak self] in
            self?.endActivity(identifier)
        }
        locked { live.append((id: identifier, token: token)) }
        return token
    }

    // MARK: - Оснастка токена

    private func endActivity(_ identifier: Int) {
        log.record(port: Self.portName, method: "PowerActivityToken.end()", arguments: [String(identifier)])
        locked {
            endCalls += 1
            live.removeAll { $0.id == identifier }
        }
    }
}
