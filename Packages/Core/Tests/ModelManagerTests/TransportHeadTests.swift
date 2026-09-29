//  C-014 v7 §6 (IR-141 п. 5; MEE-459): шов отдаёт статус в `head` ДО тела. На ответе `200`
//  `.part` усекается до нуля и пишется с начала — его длина не превосходит `files[].sizeBytes`
//  ни в один момент (п. 4; инв. 17, 29). Отказ сервера не пишет в `.part` ни байта тела.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class TransportHeadTests: XCTestCase {

    private let size = 100

    /// Модель из одного файла в 100 байт, прерванная на 40-м байте: `.part` длины 40.
    private struct Stand {
        let harness: ModelHarness
        let manager: ModelCatalogManager
        let model: TestModel
        let part: URL
    }

    private func interrupted() async throws -> Stand {
        let model = TestModel.make(id: "head-asr", files: [("h.bin", TestModel.bytes(size, seed: 50))])
        let harness = ModelHarness(models: [model])
        harness.transport.chunkSize = 10
        harness.transport.script(model.url("h.bin"), [.dropAfter(bytes: 40)])
        let manager = try harness.makeManager()
        _ = try? await manager.download(id: "head-asr", version: "1.0.0")
        let part = harness.directory(model).appendingPathComponent("h.bin.part")
        XCTAssertEqual(harness.fileSize(part), 40, "вектор: .part длины L = 40")
        return Stand(harness: harness, manager: manager, model: model, part: part)
    }

    func test_on200PartNeverExceedsFileSizeAndRestartsFromZero() async throws {
        let stand = try await interrupted()
        let harness = stand.harness, manager = stand.manager, model = stand.model, part = stand.part
        harness.transport.script(model.url("h.bin"), [.ignoreRange])
        let sizes = Probe<[Int64]>([])
        harness.transport.onChunk { _, _ in
            sizes.update { $0.append(ModelDisk.size(of: part) ?? -1) }
        }
        try await manager.download(id: "head-asr", version: "1.0.0")

        XCTAssertEqual(harness.transport.requests(for: model.url("h.bin")).map(\.firstByte), [0, 40],
                       "вектор: запрос с Range, ответ 200")
        XCTAssertEqual(sizes.value.count, 10, "вектор: наблюдение после каждой порции")
        XCTAssertEqual(sizes.value.first, 10, "после первой порции — ровно она: .part усечён до нуля ДО тела")
        XCTAssertLessThanOrEqual(sizes.value.max() ?? .max, Int64(size), "длина .part ≤ sizeBytes")
        let state = await manager.state(id: "head-asr", version: "1.0.0")
        XCTAssertEqual(state, .downloaded)
    }

    func test_on200FractionDropsOnceToTruncatedPartThenGrows() async throws {
        let stand = try await interrupted()
        let harness = stand.harness, manager = stand.manager, model = stand.model
        harness.transport.script(model.url("h.bin"), [.ignoreRange])
        let recorder = EventRecorder(manager.events())
        try await manager.download(id: "head-asr", version: "1.0.0")
        await recorder.settle { $0.contains(.stateChanged(modelId: "head-asr", version: "1.0.0", state: .downloaded)) }
        let fractions = recorder.states(of: "head-asr").compactMap { state -> Double? in
            if case .downloading(let fraction) = state { return fraction }
            return nil
        }
        // Инв. 29: убывание — только при усечении `.part` на ответе `200`, и только одно: 0,4 → 0,1.
        XCTAssertEqual(fractions.first, 0.4, "начало — занятый объём L / sizeBytes")
        XCTAssertTrue(fractions.contains(0.1), "после первой порции — доля с нуля, а не 0,5: \(fractions)")
        let drops = zip(fractions, fractions.dropFirst()).filter { $0.1 < $0.0 }
        XCTAssertEqual(drops.count, 1, "\(fractions)")
    }

    func test_serverErrorStatusWritesNoBodyBytesIntoPart() async throws {
        let stand = try await interrupted()
        let harness = stand.harness, manager = stand.manager, model = stand.model, part = stand.part
        let refusal = FakeStep.respond(status: 503, firstByte: nil, body: Data(repeating: 7, count: 30))
        harness.transport.script(model.url("h.bin"), [refusal])
        do {
            try await manager.download(id: "head-asr", version: "1.0.0")
            XCTFail("503 — отказ")
        } catch ModelCatalogError.downloadFailed {
        }
        XCTAssertEqual(harness.fileSize(part), 40, "тело ответа-отказа в .part не попало")
    }
}
