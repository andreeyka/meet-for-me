//  К19, К21 перечня MEE-429 в редакции поправки `d999d708` (C-014 v7 §6, IR-141 п. 5; MEE-459):
//  шов отдаёт статус в `head` ДО тела. `200` — `.part` усечён до нуля к возврату `head`, длина
//  не превосходит `sizeBytes`; `206` с чужим первым байтом либо `416` — `head` бросает, `.part`
//  удалён, тело не читается, один повтор с нуля. Плюс: тело ответа-отказа в `.part` не пишется.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class TransportHeadTests: XCTestCase {

    private let size = 100

    private struct Stand {
        let harness: ModelHarness
        let manager: ModelCatalogManager
        let model: TestModel
        let part: URL

        var url: URL { model.url("h.bin") }
    }

    /// Модель из одного файла в 100 байт, прерванная на 40-м байте: `.part` длины L = 40.
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

    // MARK: - К19

    func test_k19_on200PartTruncatedByHeadReturnNeverExceedsSizeFractionMonotoneValidModel() async throws {
        let stand = try await interrupted()
        let manager = stand.manager, part = stand.part
        stand.harness.transport.script(stand.url, [.ignoreRange])
        let atHead = Probe<[Int64]>([])
        stand.harness.transport.onHead { _, response, threw in
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertFalse(threw, "200 — не отказ")
            atHead.update { $0.append(ModelDisk.size(of: part) ?? 0) }
        }
        let sizes = Probe<[Int64]>([])
        let fractions = Probe<[Double]>([])
        stand.harness.transport.onChunk { _, _ in
            sizes.update { $0.append(ModelDisk.size(of: part) ?? -1) }
            if case .downloading(let fraction) = await manager.state(id: "head-asr", version: "1.0.0") {
                fractions.update { $0.append(fraction) }
            }
        }
        try await manager.download(id: "head-asr", version: "1.0.0")

        XCTAssertEqual(stand.harness.transport.requests(for: stand.url).map(\.firstByte), [0, 40],
                       "вектор: запрос с Range, ответ 200")
        XCTAssertEqual(atHead.value, [0], "к возврату head .part усечён до нуля")
        XCTAssertEqual(sizes.value.count, 10, "вектор: наблюдение после каждой порции")
        XCTAssertLessThanOrEqual(sizes.value.max() ?? .max, Int64(size), "длина .part ≤ sizeBytes")
        XCTAssertEqual(fractions.value.count, 10, "вектор: fraction изнутри receive (приём К29)")
        XCTAssertEqual(fractions.value, fractions.value.sorted(), "fraction от порции к порции не убывает")
        let final = stand.harness.directory(stand.model).appendingPathComponent("h.bin")
        XCTAssertEqual(try Data(contentsOf: final), stand.model.contents["h.bin"], "файл переписан с нуля")
        let state = await manager.state(id: "head-asr", version: "1.0.0")
        XCTAssertEqual(state, .downloaded, "не ошибка — итог валидная модель")
    }

    // MARK: - К21

    func test_k21_mismatched206Or416HeadThrowsPartGoneNoBodyThenOneRestartThenDownloadFailed() async throws {
        let refusals: [(String, FakeStep)] = [
            ("206 с чужим первым байтом", .respond(status: 206, firstByte: 20, body: TestModel.bytes(80, seed: 1))),
            ("416", .respond(status: 416, firstByte: nil, body: TestModel.bytes(10, seed: 2)))
        ]
        for (name, refusal) in refusals {
            // Отказ один раз — `head` бросает, `.part` уже нет, тело не читалось; повтор с нуля успешен.
            let once = try await interrupted()
            let part = once.part
            let partAtThrow = Probe<[Bool]>([])
            once.harness.transport.onHead { _, _, threw in
                if threw { partAtThrow.update { $0.append(ModelDisk.exists(part)) } }
            }
            once.harness.transport.script(once.url, [refusal])
            try await once.manager.download(id: "head-asr", version: "1.0.0")
            XCTAssertEqual(partAtThrow.value, [false], "\(name): head бросил, .part к этому моменту удалён")
            XCTAssertEqual(once.harness.transport.requests(for: once.url).map(\.firstByte), [0, 40, 0], name)
            XCTAssertEqual(once.harness.transport.receives[1], 0, "\(name): receive отказанного запроса — ни разу")
            let onceState = await once.manager.state(id: "head-asr", version: "1.0.0")
            XCTAssertEqual(onceState, .downloaded, name)

            // Отказ повторно — `downloadFailed`, ровно один рестарт.
            let twice = try await interrupted()
            twice.harness.transport.script(twice.url, [refusal, refusal])
            do {
                try await twice.manager.download(id: "head-asr", version: "1.0.0")
                XCTFail("\(name): ожидался downloadFailed")
            } catch ModelCatalogError.downloadFailed {
            }
            XCTAssertEqual(twice.harness.transport.requests(for: twice.url).map(\.firstByte), [0, 40, 0],
                           "\(name): ровно один рестарт")
            XCTAssertEqual(Array(twice.harness.transport.receives.suffix(2)), [0, 0], name)
        }
    }

    // MARK: - Ответ-отказ

    func test_serverErrorStatusWritesNoBodyBytesIntoPart() async throws {
        let stand = try await interrupted()
        let refusal = FakeStep.respond(status: 503, firstByte: nil, body: Data(repeating: 7, count: 30))
        stand.harness.transport.script(stand.url, [refusal])
        do {
            try await stand.manager.download(id: "head-asr", version: "1.0.0")
            XCTFail("503 — отказ")
        } catch ModelCatalogError.downloadFailed {
        }
        XCTAssertEqual(stand.harness.fileSize(stand.part), 40, "тело ответа-отказа в .part не попало")
        XCTAssertEqual(stand.harness.transport.receives.last, 0)
    }
}
