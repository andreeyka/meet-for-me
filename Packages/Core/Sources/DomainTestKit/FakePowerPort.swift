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

    private let lock = NSLock()
    private var current: PowerSnapshot
    private var continuations: [AsyncStream<PowerEvent>.Continuation] = []
    private var live: [(id: Int, token: FakePowerActivityToken)] = []
    private var nextId = 0

    /// - Parameter snapshot: стартовый снимок; умолчания нет намеренно — «пустого» `PowerSnapshot`
    ///   не существует, и всякое значение здесь есть вход теста, а не решение фейка.
    public init(snapshot: PowerSnapshot) {
        current = PowerSnapshot(
            source: snapshot.source,
            batteryFraction: snapshot.batteryFraction.map { min(max($0, 0), 1) },
            isLowPowerModeEnabled: snapshot.isLowPowerModeEnabled,
            thermalPressure: snapshot.thermalPressure,
            checkedAt: snapshot.checkedAt)
    }

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

    // MARK: - PowerPort

    public func snapshot() async -> PowerSnapshot {
        locked { current }
    }

    public func events() -> AsyncStream<PowerEvent> {
        AsyncStream { continuation in
            locked { continuations.append(continuation) }
        }
    }

    public func beginActivity(reason: PowerActivityReason, label: String) async -> PowerActivityToken {
        let identifier = locked { () -> Int in
            nextId += 1
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
        locked { live.removeAll { $0.id == identifier } }
    }
}
