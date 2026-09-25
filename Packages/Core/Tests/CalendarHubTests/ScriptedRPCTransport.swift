//  ScriptedRPCTransport — фейк Ш2 (C-006, раздел «Фейк для тестов», v9 IR-118): проигрывает
//  заранее записанный сценарий кадров-ответов без запуска процесса (план MEE-361, §1).
//  Форма (как задаётся сценарий) — решение этой задачи, не цитата контракта: очередь строк
//  JSON Lines, `receive()` отдаёт их по порядку независимо от того, что послал хост — это
//  и позволяет К46 буквально (сценарий отвечает «неверным» `id`, которого хост не посылал).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен (тестовая оснастка)

import Foundation
@testable import CalendarHub

/// Не `preconditionFailure`: сценарий, исчерпанный из-за реальной ошибки хоста (лишний,
/// неожиданный `receive()`), не должен ронять весь процесс `swift test` — обязан дать чистый
/// провал ИМЕННО этого теста, тем же путём, что и любая другая ошибка транспорта
/// (`StdioCalendarConnector.awaitResponse` отображает её в `ConnectorError.upstreamUnavailable`).
struct ScriptedRPCTransportExhausted: Error {}

final class ScriptedRPCTransport: RPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String] = []
    private var sentFrames: [String] = []

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var sent: [String] { locked { sentFrames } }

    /// Добавляет кадры-ответы в очередь воспроизведения, в порядке вызова.
    func enqueue(_ frames: String...) {
        locked { responses.append(contentsOf: frames) }
    }

    func send(_ frame: String) async throws {
        locked { sentFrames.append(frame) }
    }

    func receive() async throws -> String {
        guard let next = locked({ responses.isEmpty ? nil : responses.removeFirst() }) else {
            throw ScriptedRPCTransportExhausted()
        }
        return next
    }
}
