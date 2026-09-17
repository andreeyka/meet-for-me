//  PortCallLog — журнал вызовов портов с сохранённым порядком. Условие `Н` плана MEE-288 §2.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ЖУРНАЛ ОДИН НА ВСЕ ФЕЙКИ, И ЭТО РЕШЕНИЕ, А НЕ УДОБСТВО. Условие `Н` требует
//  последовательности, а не счётчика, и требует её ПОПЕРЁК портов: К77 просит наблюсти
//  «`RecordingRepository.save` → вход в `processing` → `JobQueue.submit`», К40 — «сохранение
//  → вход → постановка», К81 (i) — «`setStatus` вызван прежде, чем снимок опубликован».
//  Два порознь заведённых журнала на это не отвечают ничем: у каждого свой порядок, и
//  «прежде» между ними не определено. Поэтому фейк принимает журнал извне, а когда его не
//  дали — заводит свой.
//
//  ЧТО ЖУРНАЛ НЕ ХРАНИТ, названо, потому что молчание о границе читается как её отсутствие.
//  Аргументы лежат ТЕКСТОМ, а не значениями: `PortCall` обязан быть `Equatable` и `Sendable`
//  у всех портов разом, а типы аргументов у них общего надтипа не имеют — `Any` отняло бы
//  оба. Текст даёт порядок, счёт и различимость вызовов; проверять по нему РАВЕНСТВО
//  доменного значения нельзя — для этого у фейков стоят типизованные списки (`submissions`
//  у `FakeJobQueue`, `recordedCommands` у `FakeSessionCoordinator`, `recordedCalls` у
//  `FakeAudioCapturePort`), и они же — единственное, на что опираются утверждения о полях.
//
//  Журнал есть НАБЛЮДАЕМОСТЬ, а не утверждение о поведении порта: из того, что в нём
//  записано, не следует ни одного разрешения реализатору.

import Foundation

/// Один вызов, ушедший наружу через порт.
public struct PortCall: Equatable, Sendable {

    /// Имя порта, а не фейка: журнал читают критерии, писанные на порт (`MeetingRepository`).
    public let port: String

    /// Имя метода с метками аргументов, дословно по подписи контракта.
    public let method: String

    /// Аргументы в порядке подписи, описанные текстом. Пустой массив — метод без аргументов.
    public let arguments: [String]

    public init(port: String, method: String, arguments: [String]) {
        self.port = port
        self.method = method
        self.arguments = arguments
    }

    /// `"MeetingRepository.setStatus(_:meetingId:)"` — ключ, которым пункты плана называют вызов.
    public var signature: String {
        "\(port).\(method)"
    }
}

/// Последовательность вызовов, общая для всех фейков, которым её дали.
public final class PortCallLog: @unchecked Sendable {

    private let lock = NSLock()
    private var entries: [PortCall] = []

    public init() {}

    /// Замок вокруг состояния. Своя обёртка, а не `NSLocking.withLock`: та пришла в Foundation
    /// позже минимальной версии тулчейна, на которой собирается работа CI `Core (Linux)`.
    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Запись; зовут её фейки

    public func record(port: String, method: String, arguments: [String] = []) {
        let call = PortCall(port: port, method: method, arguments: arguments)
        locked { entries.append(call) }
    }

    /// Отметка о событии, которое портом не является, — вход в состояние, публикация снимка.
    /// Нужна К40 и К77 дословно: там «прежде» стоит между вызовом порта и переходом машины,
    /// и без общей шкалы эти два наблюдения несравнимы.
    public func mark(_ name: String, arguments: [String] = []) {
        record(port: "mark", method: name, arguments: arguments)
    }

    // MARK: - Чтение; зовут его тесты

    /// Все вызовы в порядке совершения.
    public var calls: [PortCall] {
        locked { entries }
    }

    /// Подписи всех вызовов в порядке совершения: `["MeetingRepository.save(_:)", …]`.
    public var signatures: [String] {
        locked { entries }.map(\.signature)
    }

    public func calls(port: String) -> [PortCall] {
        locked { entries }.filter { $0.port == port }
    }

    public func count(port: String, method: String) -> Int {
        locked { entries }.filter { $0.port == port && $0.method == method }.count
    }

    /// Номер первого вызова в последовательности; `nil` — вызова не было.
    /// Им и проверяется «прежде»: `first(of:) < first(of:)` — утверждение о порядке,
    /// а не о том, что оба случились.
    public func firstIndex(of signature: String) -> Int? {
        locked { entries }.firstIndex { $0.signature == signature }
    }

    /// Номер последнего вызова; `nil` — вызова не было.
    public func lastIndex(of signature: String) -> Int? {
        locked { entries }.lastIndex { $0.signature == signature }
    }

    /// `true`, если оба вызова были и первый случился прежде второго.
    /// Отсутствие любого из двух даёт `false`: «прежде» о несостоявшемся вызове не утверждается.
    public func happened(_ earlier: String, before later: String) -> Bool {
        guard let first = firstIndex(of: earlier), let second = firstIndex(of: later) else {
            return false
        }
        return first < second
    }

    public var isEmpty: Bool {
        locked { entries.isEmpty }
    }

    public func clear() {
        locked { entries.removeAll() }
    }
}
