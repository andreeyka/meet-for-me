//  К26–К31, К47, К48 перечня MEE-429 (план MEE-436, группа Ж и К47/К48 группы Н): отмена,
//  пауза, занятый объём (§4.2) и удаление. Занятый объём сверяется с независимым замером
//  диска (`ModelHarness.occupied`), а не с числом из реализации.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class CancelPauseUsageTests: XCTestCase {

    /// Ждёт, пока тестовый транспорт получит хотя бы `count` запросов.
    func waitForRequests(_ harness: ModelHarness, count: Int = 1) async {
        let deadline = Date().addingTimeInterval(5)
        while harness.transport.requests.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func test_k26_cancelBeforeFirstByteLeavesNoPartFile() async throws {
        let model = TestModel.make(id: "cancel-early", files: [("c.bin", TestModel.bytes(64, seed: 15))])
        let harness = ModelHarness(models: [model])
        harness.transport.script(model.url("c.bin"), [.waitForCancellation])
        let manager = try harness.makeManager()
        let download = Task { try await manager.download(id: "cancel-early", version: "1.0.0") }
        await waitForRequests(harness)
        let during = await manager.state(id: "cancel-early", version: "1.0.0")
        XCTAssertEqual(during, .downloading(fraction: 0), "вектор: загрузка идёт, байт ещё нет")
        await manager.cancelDownload(id: "cancel-early", version: "1.0.0")
        do {
            try await download.value
            XCTFail("отменённая загрузка не завершается успехом")
        } catch ModelCatalogError.cancelled {
        }
        let state = await manager.state(id: "cancel-early", version: "1.0.0")
        XCTAssertEqual(state, .available, "available, не paused")
        XCTAssertFalse(harness.exists(harness.directory(model).appendingPathComponent("c.bin.part")))
        XCTAssertFalse(harness.exists(harness.directory(model)), "на диске нет ни байта")
    }

    func test_k27_k28_pausedBytesOnDiskEqualsDiskUsageBytesOnDiskSameTest() async throws {
        // Пропорции §2: model.int8.onnx докачан целиком (226 Б), vocab.txt.part — 6 Б из 10.
        let model = TestModel.gigaamLike()
        let harness = ModelHarness(models: [model])
        harness.transport.script(model.url("vocab.txt"), [.dropAfter(bytes: 6)])
        let manager = try harness.makeManager()
        do {
            try await manager.download(id: model.descriptor.id, version: model.descriptor.version)
            XCTFail("обрыв на втором файле")
        } catch ModelCatalogError.downloadFailed {
        }
        let directory = harness.directory(model)
        XCTAssertEqual(harness.fileSize(directory.appendingPathComponent("model.int8.onnx")), 226)
        XCTAssertEqual(harness.fileSize(directory.appendingPathComponent("vocab.txt.part")), 6)

        let state = await manager.state(id: model.descriptor.id, version: model.descriptor.version)
        XCTAssertEqual(state, .paused(bytesOnDisk: 232), "К27: занятый объём — оба файла, не только .part (6)")
        XCTAssertEqual(harness.occupied(model), 232, "независимый замер диска")
        let usage = await manager.diskUsage()
        XCTAssertEqual(usage, [ModelDiskUsage(modelId: model.descriptor.id, version: "1.0.0", bytesOnDisk: 232)],
                       "К28: diskUsage — то же n на том же состоянии диска")
    }

    func test_k29_downloadingFractionTripleEqualityWithDiskLengthAndPausedBytesOnDisk() async throws {
        let model = TestModel.gigaamLike()
        let harness = ModelHarness(models: [model])
        harness.transport.chunkSize = 16
        let manager = try harness.makeManager()
        let observed = Probe<[(fractionBytes: Int64, diskBytes: Int64)]>([])
        let firstURL = model.url("model.int8.onnx")
        harness.transport.onChunk { url, index in
            guard url == firstURL else { return }
            let state = await manager.state(id: model.descriptor.id, version: model.descriptor.version)
            guard case .downloading(let fraction) = state else {
                return XCTFail("изнутри receive — downloading, получено \(state)")
            }
            let fractionBytes = Int64((fraction * Double(model.descriptor.sizeBytes)).rounded())
            observed.update { $0.append((fractionBytes, harness.occupied(model))) }
            if index == 5 {
                throw FakeNetworkError()        // обрыв связи сразу за наблюдением
            }
        }
        do {
            try await manager.download(id: model.descriptor.id, version: model.descriptor.version)
            XCTFail("соединение оборвано тестом")
        } catch ModelCatalogError.downloadFailed {
        }
        let samples = observed.value
        XCTAssertEqual(samples.count, 6, "вектор непустоты: шесть наблюдений до обрыва")
        for sample in samples {
            XCTAssertEqual(sample.fractionBytes, sample.diskBytes, "fraction * sizeBytes == длина на диске")
        }
        XCTAssertEqual(samples.map(\.fractionBytes), samples.map(\.fractionBytes).sorted(), "fraction не убывает")
        let last = try XCTUnwrap(samples.last)
        let state = await manager.state(id: model.descriptor.id, version: model.descriptor.version)
        XCTAssertEqual(state, .paused(bytesOnDisk: last.diskBytes), "bytesOnDisk после обрыва — то же число")
        XCTAssertEqual(last.diskBytes, 96)
    }

    func test_k30_diskUsageOmitsModelsWithNoCatalogOnDisk() async throws {
        let present = TestModel.make(id: "present", files: [("p.bin", TestModel.bytes(20, seed: 16))])
        let absent = TestModel.make(id: "absent", files: [("a.bin", TestModel.bytes(20, seed: 17))])
        let harness = ModelHarness(models: [present, absent])
        let manager = try harness.makeManager()
        let empty = await manager.diskUsage()
        XCTAssertTrue(empty.isEmpty, "ничего не скачано — нулевых строк нет")
        try await manager.download(id: "present", version: "1.0.0")
        let usage = await manager.diskUsage()
        XCTAssertEqual(usage.map(\.modelId), ["present"])
        let absentState = await manager.state(id: "absent", version: "1.0.0")
        XCTAssertEqual(absentState, .available)
    }

    func test_k31_diskUsageEqualsSizeBytesPlusManifestFileLength() async throws {
        let model = TestModel.gigaamLike()
        let harness = ModelHarness(models: [model])
        let manager = try harness.makeManager()
        try await manager.download(id: model.descriptor.id, version: model.descriptor.version)
        let manifestLength = harness.fileSize(harness.directory(model).appendingPathComponent(".manifest.json"))
        XCTAssertGreaterThan(manifestLength, 0, "вектор: .manifest.json записан")
        let usage = await manager.diskUsage()
        XCTAssertEqual(usage.first?.bytesOnDisk, model.descriptor.sizeBytes + manifestLength)
    }
}
