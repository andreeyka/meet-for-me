//  К47, К48 перечня MEE-429 (группа Н): отмена после первого байта → `paused` с `.part`;
//  успешный `delete` из четырёх состояний → каталог модели удалён целиком, `available`.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

extension CancelPauseUsageTests {

    func test_k47_cancelAfterFirstBytePausesAndKeepsPartFile() async throws {
        let model = TestModel.make(id: "cancel-late", files: [("l.bin", TestModel.bytes(100, seed: 18))])
        let harness = ModelHarness(models: [model])
        harness.transport.chunkSize = 16
        let manager = try harness.makeManager()
        harness.transport.onChunk { _, index in
            if index == 0 {
                await manager.cancelDownload(id: "cancel-late", version: "1.0.0")
            }
        }
        do {
            try await manager.download(id: "cancel-late", version: "1.0.0")
            XCTFail("отменённая загрузка не завершается успехом")
        } catch ModelCatalogError.cancelled {
        }
        let part = harness.directory(model).appendingPathComponent("l.bin.part")
        XCTAssertEqual(harness.fileSize(part), 16, ".part остаётся для возобновления, не усечён")
        let state = await manager.state(id: "cancel-late", version: "1.0.0")
        XCTAssertEqual(state, .paused(bytesOnDisk: 16))

        harness.transport.onChunk(nil)
        try await manager.download(id: "cancel-late", version: "1.0.0")
        XCTAssertEqual(harness.transport.requests.map(\.firstByte), [0, 16], "продолжение с .part")
    }

    func test_k48_deleteFromDownloadedPausedDownloadingOrErrorRemovesCatalogEntirelyToAvailable() async throws {
        let downloaded = TestModel.make(id: "del-downloaded", files: [("a.bin", TestModel.bytes(40, seed: 19))])
        let paused = TestModel.make(id: "del-paused", files: [("b.bin", TestModel.bytes(40, seed: 20))])
        let running = TestModel.make(id: "del-running", files: [("c.bin", TestModel.bytes(40, seed: 21))])
        let broken = TestModel.make(id: "del-error", files: [("d.bin", TestModel.bytes(40, seed: 22))])
        let harness = ModelHarness(models: [downloaded, paused, running, broken])
        harness.transport.chunkSize = 8
        harness.transport.script(paused.url("b.bin"), [.dropAfter(bytes: 20)])
        harness.transport.setContent(TestModel.bytes(40, seed: 99), at: broken.url("d.bin"))
        let manager = try harness.makeManager()

        try await manager.download(id: "del-downloaded", version: "1.0.0")
        _ = try? await manager.download(id: "del-paused", version: "1.0.0")
        _ = try? await manager.download(id: "del-error", version: "1.0.0")
        let runningURL = running.url("c.bin")
        let stateDuringDelete = Probe<ModelState?>(nil)
        harness.transport.onChunk { url, index in
            guard url == runningURL, index == 1 else { return }
            let before = await manager.state(id: "del-running", version: "1.0.0")
            stateDuringDelete.update { $0 = before }
            try await manager.delete(id: "del-running", version: "1.0.0")
        }
        _ = try? await manager.download(id: "del-running", version: "1.0.0")
        XCTAssertEqual(stateDuringDelete.value?.isDownloading, true, "вектор: delete пришёл в downloading")

        let expectedBefore: [String: (ModelState) -> Bool] = [
            "del-downloaded": { $0 == .downloaded },
            "del-paused": { $0 == .paused(bytesOnDisk: 20) },
            "del-error": { if case .error(.checksumMismatch) = $0 { return true } else { return false } }
        ]
        for (id, check) in expectedBefore {
            let before = await manager.state(id: id, version: "1.0.0")
            XCTAssertTrue(check(before), "вектор: \(id) до delete — \(before)")
            try await manager.delete(id: id, version: "1.0.0")
        }
        for model in [downloaded, paused, running, broken] {
            XCTAssertFalse(harness.exists(harness.directory(model)), "\(model.descriptor.id): каталог удалён целиком")
            let state = await manager.state(id: model.descriptor.id, version: "1.0.0")
            XCTAssertEqual(state, .available, model.descriptor.id)
        }
    }
}
