//  MachineEnvironment — внутренний шов «чип, память, свободное место» (C-014 инв. 16, 17).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  `internal`, тем же приёмом, что `ModelFileTransport` (решение РП по К24/К25, MEE-429
//  `0959c44a`): на `Core (Linux)` подменить системный вызов нечем, кроме шва. Боевая
//  реализация — `SystemMachineEnvironment` ниже, без macOS-фреймворков (инв. 20).

import Foundation
import DomainCore

protocol MachineEnvironment: Sendable {
    /// Чип машины; `nil` — не распознан (не Apple Silicon или Linux): порог не применяется.
    func chip() -> MinChip?
    /// Физическая память в байтах.
    func physicalMemoryBytes() -> UInt64
    /// Свободное место на томе, где лежит `url`; `nil` — не удалось узнать: порог не применяется.
    func availableDiskBytes(at url: URL) -> Int64?
}

struct SystemMachineEnvironment: MachineEnvironment {

    func chip() -> MinChip? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
        return Self.chip(fromBrand: String(cString: bytes))
        #else
        return nil
        #endif
    }

    func physicalMemoryBytes() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// MEE-458 п.3: на macOS — `volumeAvailableCapacityForImportantUsage`: место, которое
    /// система готова отдать под важные данные пользователя (с учётом очищаемого — кешей,
    /// локальных снимков), а не `systemFreeSize`, который его не считает и на APFS занижает
    /// доступное. Ключа нет на swift-corelibs, поэтому на Linux — `systemFreeSize`, как прежде.
    /// Если на macOS ключ не отдал значения, берётся тот же `systemFreeSize`.
    func availableDiskBytes(at url: URL) -> Int64? {
        let probe = Self.existingAncestor(of: url)
        #if os(macOS)
        if let important = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            return important
        }
        #endif
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: probe.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Каталог модели на момент проверки ещё не создан — спрашиваем ближайшего существующего предка.
    static func existingAncestor(of url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        return probe
    }

    /// «Apple M2 Pro» → `.m2`; чип новее `m4` считается `m4` — старше него `MinChip` не знает.
    static func chip(fromBrand brand: String) -> MinChip? {
        guard let range = brand.range(of: "Apple M") else { return nil }
        let digits = brand[range.upperBound...].prefix { $0.isNumber }
        guard let generation = Int(digits), generation >= 1 else { return nil }
        return MinChip(rawValue: "m\(min(generation, 4))")
    }
}
