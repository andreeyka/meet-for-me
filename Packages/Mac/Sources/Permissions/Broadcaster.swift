//  Broadcaster — раздача значений всем подписчикам `AsyncStream` в одном порядке.
//
//  Общая часть `changes()` C-007 и `events()` C-008: поток отдаёт только то, что опубликовано
//  после подписки; несколько подписчиков получают одинаковую последовательность в одинаковом
//  порядке; завершение итерации снимает наблюдателя (C-007 «Данные на границе»).

import Foundation

final class Broadcaster<Element: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    /// Число живых наблюдателей — вход критерия 36.
    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    func stream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    /// Публикация под замком: два одновременных вызова не перемешивают порядок у подписчиков.
    func send(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }
        for continuation in continuations.values {
            continuation.yield(element)
        }
    }

    func finishAll() {
        lock.lock()
        let all = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in all {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        continuations[id] = nil
    }
}
