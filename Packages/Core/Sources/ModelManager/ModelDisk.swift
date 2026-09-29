//  ModelDisk — раскладка каталога модели и замеры по диску (C-014 v7 §4.2, §5).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  «Занятый моделью объём» (§4.2) — сумма фактических длин ВСЕХ файлов каталога модели,
//  включая `.part` и `.manifest.json`, измеренная по диску, а не взятая из манифеста.
//  Одна величина на три места: `diskUsage`, `paused(bytesOnDisk:)`, числитель `fraction`.

import Foundation

enum ModelDisk {
    static let manifestName = ".manifest.json"
    static let partSuffix = ".part"

    static func partURL(in directory: URL, name: String) -> URL {
        directory.appendingPathComponent(name + partSuffix)
    }

    static func fileURL(in directory: URL, name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent(manifestName)
    }

    /// Длина обычного файла; `nil` — файла нет.
    static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Занятый моделью объём (§4.2): все файлы каталога, включая скрытые.
    static func occupiedBytes(in directory: URL) -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(Int64(0)) { total, name in
            total + (size(of: directory.appendingPathComponent(name)) ?? 0)
        }
    }

    static func remove(_ url: URL) throws {
        if exists(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Усекает файл до `length` байт (ответ `200` на запрос с `Range`, §6 п. 4 — до нуля).
    static func truncate(_ url: URL, to length: Int64) throws {
        guard let current = size(of: url), current > length else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
    }

    /// Каталоги моделей на диске: `models/<engine>/<id>@<version>/` → (id, version, каталог).
    static func modelDirectories(root: URL) -> [(key: ModelKey, directory: URL)] {
        let modelsRoot = root.appendingPathComponent("models")
        var found: [(key: ModelKey, directory: URL)] = []
        for engine in directories(in: modelsRoot) {
            for directory in directories(in: engine) {
                let name = directory.lastPathComponent
                guard let separator = name.lastIndex(of: "@") else { continue }
                let key = ModelKey(id: String(name[..<separator]),
                                   version: String(name[name.index(after: separator)...]))
                found.append((key, directory))
            }
        }
        return found
    }

    private static func directories(in url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.sorted().compactMap { name in
            var isDirectory: ObjCBool = false
            let child = url.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return child
        }
    }
}

/// Пара (`id`, `version`) — ключ модели во всех таблицах `model-manager`.
struct ModelKey: Hashable, Sendable {
    let id: String
    let version: String
}
