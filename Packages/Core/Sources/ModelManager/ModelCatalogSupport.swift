//  Вспомогательные типы `ModelCatalogManager`: рассылка событий, сеанс загрузки, буфер байт,
//  сравнение версий.
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети

import Foundation
import DomainCore

/// Рассылка `ModelCatalogEvent` подписчикам (C-014 «Поведение»: события — после подписки).
/// `events()` порта синхронный, поэтому подписчики живут под замком, а не в состоянии актора.
final class ModelEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ModelCatalogEvent>.Continuation] = [:]

    func stream() -> AsyncStream<ModelCatalogEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    func yield(_ event: ModelCatalogEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

/// Идущая загрузка одной модели. Меняется только на акторе `ModelCatalogManager`; в замыкание
/// `receive` передаётся лишь как ключ сверки (`===`), поэтому `@unchecked Sendable`.
final class DownloadSession: @unchecked Sendable {
    var cancelRequested = false
    var deleted = false
    var fetchTask: Task<HTTPRangeResponse, Error>?
    var partURL: URL?
    var handle: FileHandle?
    var publishedPercent = -1

    var isStopped: Bool { cancelRequested || deleted }

    func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    func stop() {
        fetchTask?.cancel()
        closeHandle()
    }
}

/// Накопитель байт каталога: `receive` — `@Sendable`, локальную переменную он менять не вправе.
final class ByteAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ chunk: Data) {
        lock.lock()
        bytes.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

/// Отказы загрузки, различаемые внутри `download` до перевода в `ModelCatalogError`.
enum DownloadFailure: Error {
    case http(String)
    case checksum(fileName: String, expected: String, actual: String)
}

/// Итог сверки `sha256` файлов модели на диске — кешируется до загрузки или удаления:
/// файлы модели меняет только `model-manager` («Данные на границе»).
enum Verification {
    case passed
    case failed(ModelCatalogError)
}

enum ModelVersionOrder {
    /// «Новее» по semver: числовые компоненты сравниваются числом, прочие — строкой.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".")
        let right = rhs.split(separator: ".")
        for (leftPart, rightPart) in zip(left, right) where leftPart != rightPart {
            if let leftNumber = Int(leftPart), let rightNumber = Int(rightPart) {
                return leftNumber > rightNumber
            }
            return leftPart > rightPart
        }
        return left.count > right.count
    }
}
