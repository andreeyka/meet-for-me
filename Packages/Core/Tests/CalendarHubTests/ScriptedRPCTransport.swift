//  ScriptedRPCTransport — фейк Ш2 (C-006, раздел «Фейк для тестов», v9 IR-118): проигрывает
//  заранее записанный сценарий кадров-ответов без запуска процесса (план MEE-361, §1).
//  Форма (как задаётся сценарий) — решение этой задачи, не цитата контракта: очередь строк
//  JSON Lines, `receive()` отдаёт их по порядку независимо от того, что послал хост — это
//  и позволяет К46 буквально (сценарий отвечает «неверным» `id`, которого хост не посылал).
//  `hangOnNextReceive()` (МЕЕ-386, К9 вход Б) — та же очередь, отдельный элемент: единственный
//  способ смоделировать зависший вызов плагина на stdio-пути для `raceTimeout`.
//  `resolvePendingHang(with:)` (МЕЕ-386, К12) — отпускает зависание настоящим кадром-ответом,
//  не отменой задачи: держит первый вызов «без ответа» ровно до нужного момента теста, вместо
//  того чтобы моделировать реальное зависание плагина.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен (тестовая оснастка)

import Foundation
@testable import CalendarHub

/// Не `preconditionFailure`: сценарий, исчерпанный из-за реальной ошибки хоста (лишний,
/// неожиданный `receive()`), не должен ронять весь процесс `swift test` — обязан дать чистый
/// провал ИМЕННО этого теста, тем же путём, что и любая другая ошибка транспорта
/// (`StdioCalendarConnector.awaitResponse` отображает её в `ConnectorError.upstreamUnavailable`).
struct ScriptedRPCTransportExhausted: Error {}

/// Элемент очереди воспроизведения — обычный кадр-ответ или зависание (МЕЕ-386, К9 вход Б).
private enum ScriptedResponse {
    case frame(String)
    case hang
}

final class ScriptedRPCTransport: RPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [ScriptedResponse] = []
    private var sentFrames: [String] = []
    private var pendingHang: CheckedContinuation<String, Error>?

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var sent: [String] { locked { sentFrames } }

    /// Добавляет кадры-ответы в очередь воспроизведения, в порядке вызова.
    func enqueue(_ frames: String...) {
        locked { responses.append(contentsOf: frames.map(ScriptedResponse.frame)) }
    }

    /// Ставит в ту же очередь, на своё место по порядку, зависание вместо кадра-ответа —
    /// `receive()`, дойдя до него, не бросает и не отвечает, а виснет НАВСЕГДА, пока
    /// вызывающая сторона (`raceTimeout`, проигравшая гонку с тайм-аутом) не отменит саму
    /// задачу. Отвечает на отмену (`withTaskCancellationHandler`) — без этого повисший вызов
    /// пережил бы сам тест, вместо того чтобы быть снятым `group.cancelAll()`.
    func hangOnNextReceive() {
        locked { responses.append(.hang) }
    }

    /// Отпускает зависший `receive()` (см. `hangOnNextReceive()`) настоящим кадром-ответом —
    /// в отличие от отмены задачи (К9 вход Б), здесь ожидающий вызов получает значение и
    /// продолжает обычным путём (К12: второй вызов может отправить свой `request` только
    /// ПОСЛЕ этого). `@discardableResult` — вызывающая сторона обычно уже знает, что зависание
    /// было поставлено, и не обязана проверять факт отпускания.
    @discardableResult
    func resolvePendingHang(with frame: String) -> Bool {
        let toResume = locked { () -> CheckedContinuation<String, Error>? in
            defer { pendingHang = nil }
            return pendingHang
        }
        toResume?.resume(returning: frame)
        return toResume != nil
    }

    func send(_ frame: String) async throws {
        locked { sentFrames.append(frame) }
    }

    func receive() async throws -> String {
        let next = locked { responses.isEmpty ? nil : responses.removeFirst() }
        switch next {
        case .none:
            throw ScriptedRPCTransportExhausted()
        case .frame(let frame):
            return frame
        case .hang:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    locked { pendingHang = continuation }
                }
            } onCancel: {
                let toResume = locked { () -> CheckedContinuation<String, Error>? in
                    defer { pendingHang = nil }
                    return pendingHang
                }
                toResume?.resume(throwing: CancellationError())
            }
        }
    }
}
