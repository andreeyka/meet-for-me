//  К55, К61 перечня MEE-429 (поправка `d999d708`, C-014 v7; MEE-459) — пункты класса (—):
//  контракт называет поведение уже реализованным. К55 — инв. 25 v7 («часть файлов готова,
//  `.part` нет»); К61 — инв. 36 (параллельный `download` ждёт идущую, отмена начавшего и ждущего).

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class ConcurrentDownloadTests: XCTestCase {

    // MARK: - К55

    func test_k55_someFilesReadyNoPartIsPausedWithSameBytesAsDiskUsageEmptyDirectoryIsNotPaused() async throws {
        let model = TestModel.make(id: "half", files: [("one.bin", TestModel.bytes(30, seed: 90)),
                                                       ("two.bin", TestModel.bytes(20, seed: 91))])
        let harness = ModelHarness(models: [model])
        let manager = try harness.makeManager()
        let directory = harness.directory(model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Б: каталог есть, файлов нет, занятый объём 0 — не `paused`.
        let empty = await manager.state(id: "half", version: "1.0.0")
        if case .paused = empty {
            XCTFail("пустой каталог — не paused")
        }

        // А: первый файл целиком под своим именем, второго нет ни под именем, ни `.part`.
        try (model.contents["one.bin"] ?? Data()).write(to: directory.appendingPathComponent("one.bin"))
        XCTAssertFalse(harness.exists(directory.appendingPathComponent("two.bin.part")), "вектор: .part нет")
        let state = await manager.state(id: "half", version: "1.0.0")
        let usage = await manager.diskUsage().first { $0.modelId == "half" }
        XCTAssertEqual(state, .paused(bytesOnDisk: 30))
        XCTAssertEqual(usage?.bytesOnDisk, 30, "то же число в diskUsage на том же диске")
    }

    // MARK: - К61

    /// Стенд: загрузка держится на первой порции, пока тест не поднимет `gate`.
    private func gated(_ id: String, content: Data? = nil) throws -> (ModelHarness, Probe<Bool>) {
        let model = TestModel.make(id: id, files: [("g.bin", TestModel.bytes(64, seed: 92))])
        let harness = ModelHarness(models: [model])
        if let content {
            harness.transport.setContent(content, at: model.url("g.bin"))
        }
        let gate = Probe(false)
        harness.transport.onChunk { _, index in
            guard index == 0 else { return }
            while !gate.value {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        return (harness, gate)
    }

    /// T1 начинает, T2 и T3 входят, пока первая порция держится. Каждая задача возвращает
    /// состояние модели в момент своего возврата.
    private func start(_ manager: ModelCatalogManager, _ harness: ModelHarness,
                       id: String) async -> [Task<ModelState, Error>] {
        func call() -> Task<ModelState, Error> {
            Task {
                try await manager.download(id: id, version: "1.0.0")
                return await manager.state(id: id, version: "1.0.0")
            }
        }
        let first = call()
        while harness.transport.requests.isEmpty {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let others = [call(), call()]
        try? await Task.sleep(nanoseconds: 50_000_000)
        return [first] + others
    }

    private func outcome(_ task: Task<ModelState, Error>) async -> Result<ModelState, ModelCatalogError> {
        do {
            return .success(try await task.value)
        } catch {
            return .failure(error as? ModelCatalogError ?? .downloadFailed(message: "\(error)"))
        }
    }

    func test_k61_waitersShareOutcomeStarterCancelStopsAllWaiterCancelDoesNot() async throws {
        // А: успех — одна загрузка, трое возвращаются после `downloaded`.
        let (okHarness, okGate) = try gated("k61-ok")
        let okManager = try okHarness.makeManager()
        let okTasks = await start(okManager, okHarness, id: "k61-ok")
        okGate.update { $0 = true }
        for task in okTasks {
            let result = await outcome(task)
            XCTAssertEqual(result, .success(.downloaded), "А: возврат только после downloaded")
        }
        XCTAssertEqual(okHarness.transport.requests.count, 1, "А: fetch на файл — как у одиночного download")

        // Б: ошибка — у всех трёх тот же случай с равными значениями.
        let (badHarness, badGate) = try gated("k61-bad", content: TestModel.bytes(64, seed: 93))
        let badManager = try badHarness.makeManager()
        let badTasks = await start(badManager, badHarness, id: "k61-bad")
        badGate.update { $0 = true }
        var failures: [Result<ModelState, ModelCatalogError>] = []
        for task in badTasks {
            failures.append(await outcome(task))
        }
        guard case .failure(.checksumMismatch)? = failures.first else {
            return XCTFail("Б: ожидался checksumMismatch, получено \(failures)")
        }
        XCTAssertEqual(Set(failures.map { "\($0)" }).count, 1, "Б: исход один на всех: \(failures)")

        // В: отмена начавшего — загрузка остановлена, все получают `cancelled`.
        let (cancelHarness, _) = try gated("k61-cancel")
        let cancelManager = try cancelHarness.makeManager()
        let cancelTasks = await start(cancelManager, cancelHarness, id: "k61-cancel")
        cancelTasks[0].cancel()
        for task in cancelTasks {
            let result = await outcome(task)
            XCTAssertEqual(result, .failure(.cancelled), "В")
        }
        let stopped = await cancelManager.state(id: "k61-cancel", version: "1.0.0")
        XCTAssertFalse(stopped.isDownloading, "В: загрузка остановлена, как cancelDownload: \(stopped)")

        // Г: отмена ждущего — загрузка продолжается, начавший возвращается без ошибки.
        let (waitHarness, waitGate) = try gated("k61-waiter")
        let waitManager = try waitHarness.makeManager()
        let waitTasks = await start(waitManager, waitHarness, id: "k61-waiter")
        waitTasks[1].cancel()
        try? await Task.sleep(nanoseconds: 20_000_000)
        waitGate.update { $0 = true }
        let starter = await outcome(waitTasks[0])
        XCTAssertEqual(starter, .success(.downloaded), "Г: начавший — без ошибки, итог downloaded")
        _ = await outcome(waitTasks[1])               // когда вернётся ждущий, критерий не утверждает
        _ = await outcome(waitTasks[2])
    }
}
