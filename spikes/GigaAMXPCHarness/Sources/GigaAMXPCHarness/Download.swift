//  Download — Z7 п. 6 (MEE-452): `ModelCatalogManager.download` из встроенного каталога по реальной
//  сети, остановка на ~50 % и повторный `download` с докачкой.
//
//  Ответ `206` виден по `.part`: на `200` менеджер усекает `.part` до нуля ДО первого байта тела
//  (C-014 §6 п. 4), на `206` с первым байтом `L` — дописывает в конец. Поэтому `.part`, ни разу
//  не ставший короче длины на паузе после повторного `download`, — это докачка по `206`.

import CryptoKit
import DomainCore
import DomainTestKit
import Foundation
import ModelManager

let modelId = "gigaam-v3-e2e-ctc-int8"
let modelVersion = "3.0.0"

func runDownload(_ arguments: [String]) async throws {
    guard let rootPath = option("--root", in: arguments), let out = option("--out", in: arguments) else {
        throw StandError.usage("download --root DIR --out JSON [--pause-at F]")
    }
    let pauseAt = option("--pause-at", in: arguments).flatMap(Double.init) ?? 0.5
    let root = URL(fileURLWithPath: rootPath)
    let manager = ModelCatalogManager(
        rootDirectory: root, catalogURL: URL(string: "https://example.invalid/catalog.json")!,
        settings: InMemorySettingsRepository()
    )
    guard let descriptor = await manager.model(id: modelId, version: modelVersion),
          let modelFile = descriptor.files.first(where: { $0.name == "model.int8.onnx" }) else {
        throw StandError.usage("во встроенном каталоге нет \(modelId)@\(modelVersion)")
    }
    let directory = FileLayout(root: root).modelDirectory(
        engine: descriptor.engine, modelId: modelId, version: modelVersion
    )
    let part = directory.appendingPathComponent("model.int8.onnx.part")
    var result: [String: Any] = ["mode": "download", "root": rootPath, "urls": descriptor.files.map(\.url.absoluteString)]
    result["stateBefore"] = "\(await manager.state(id: modelId, version: modelVersion))"

    // Первая попытка — до ~pauseAt доли файла модели, затем cancelDownload.
    let threshold = Int64(Double(modelFile.sizeBytes) * pauseAt)
    let firstStart = now()
    let first = Task { try await manager.download(id: modelId, version: modelVersion) }
    while partSize(part) < threshold {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    await manager.cancelDownload(id: modelId, version: modelVersion)
    result["firstOutcome"] = await outcome(of: first)
    result["firstS"] = now() - firstStart
    let pausedBytes = partSize(part)
    result["partBytesAtPause"] = pausedBytes
    result["stateAfterPause"] = "\(await manager.state(id: modelId, version: modelVersion))"

    // Повторная попытка: `.part` не должен становиться короче длины на паузе (иначе был `200`).
    let secondStart = now()
    let second = Task { try await manager.download(id: modelId, version: modelVersion) }
    let watcher = Task { () -> (min: Int64, firstGrowthS: Double?) in
        var minimum = Int64.max
        var growth: Double?
        while !Task.isCancelled {
            let size = partSize(part)
            if size >= 0 { minimum = min(minimum, size) }
            if growth == nil, size > pausedBytes { growth = now() - secondStart }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return (minimum, growth)
    }
    result["secondOutcome"] = await outcome(of: second)
    result["secondS"] = now() - secondStart
    watcher.cancel()
    let watched = await watcher.value
    result["partMinBytesDuringResume"] = watched.min == Int64.max ? -1 : watched.min
    result["partFirstGrowthS"] = watched.firstGrowthS ?? -1
    result["resumedBy206"] = watched.min != Int64.max && watched.min >= pausedBytes
    result["stateAfter"] = "\(await manager.state(id: modelId, version: modelVersion))"

    var files: [[String: Any]] = []
    for file in descriptor.files {
        let url = directory.appendingPathComponent(file.name)
        let actual = try sha256(of: url)
        files.append([
            "name": file.name, "sizeBytes": partSize(url), "expectedSizeBytes": file.sizeBytes,
            "sha256": actual, "expectedSha256": file.sha256, "match": actual == file.sha256
        ])
    }
    result["files"] = files
    result["manifestPresent"] = FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(".manifest.json").path
    )
    result["modelDirectory"] = directory.path
    try writeJSON(result, to: out)
    print(result)
}

func partSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
}

func outcome(of task: Task<Void, Error>) async -> String {
    do {
        try await task.value
        return "ok"
    } catch {
        return "\(error)"
    }
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
