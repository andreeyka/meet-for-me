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

/// Порядок версий по semver 2.0.0 (C-014 §1: `ModelDescriptor.version` — semver), §11.
///
/// MEE-458 п.1: pre-release младше релиза того же ядра (`3.0.0-beta` < `3.0.0`); два
/// pre-release сравниваются по идентификаторам через точку — числовой числом, числовой
/// младше буквенно-цифрового, буквенные — строкой ASCII, при равных общих — длиннее старше.
/// Метаданные сборки (`+…`) в порядке не участвуют. Ядро разной длины (`1.0` против `1.0.0`)
/// сравнивается как прежде: при равных общих компонентах старше длинное.
enum ModelVersionOrder {
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = split(lhs)
        let right = split(rhs)
        let core = compareIdentifiers(left.core, right.core, numericBelowText: false)
        if core != .orderedSame { return core }
        switch (left.preRelease, right.preRelease) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (leftPre?, rightPre?): return compareIdentifiers(leftPre, rightPre, numericBelowText: true)
        }
    }

    private static func split(_ version: String) -> (core: [Substring], preRelease: [Substring]?) {
        let withoutBuild = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let halves = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = (halves.first ?? "").split(separator: ".")
        let preRelease = halves.count == 2 ? halves[1].split(separator: ".") : nil
        return (core, preRelease)
    }

    /// `numericBelowText`: правило semver §11.4.3 для pre-release; в ядре — прежнее сравнение
    /// строкой, если хоть одна часть не число.
    private static func compareIdentifiers(
        _ left: [Substring], _ right: [Substring], numericBelowText: Bool
    ) -> ComparisonResult {
        for (leftPart, rightPart) in zip(left, right) where leftPart != rightPart {
            switch (Int(leftPart), Int(rightPart)) {
            case let (leftNumber?, rightNumber?):
                return leftNumber > rightNumber ? .orderedDescending : .orderedAscending
            case (_?, nil) where numericBelowText:
                return .orderedAscending
            case (nil, _?) where numericBelowText:
                return .orderedDescending
            default:
                return leftPart > rightPart ? .orderedDescending : .orderedAscending
            }
        }
        if left.count == right.count { return .orderedSame }
        return left.count > right.count ? .orderedDescending : .orderedAscending
    }
}
