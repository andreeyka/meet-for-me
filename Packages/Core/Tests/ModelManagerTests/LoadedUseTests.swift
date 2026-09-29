//  К32–К36 перечня MEE-429 (план MEE-436, группа З): `loaded` как счётчик расписок
//  `beginUse`/`endUse` (§4.1, инв. 21–24) и отсутствие инференса в модуле (инв. 7).

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class LoadedUseTests: XCTestCase {

    private func downloaded(_ ids: [String], available: [String] = []) async throws
        -> (ModelHarness, ModelCatalogManager) {
        let models = (ids + available).enumerated().map { index, id in
            TestModel.make(id: id, files: [("\(id).bin", TestModel.bytes(24, seed: UInt8(30 + index)))])
        }
        let harness = ModelHarness(models: models)
        let manager = try harness.makeManager()
        for id in ids {
            try await manager.download(id: id, version: "1.0.0")
        }
        return (harness, manager)
    }

    private func bundle(_ harness: ModelHarness, _ id: String) -> ModelBundle {
        let model = harness.models.first { $0.descriptor.id == id } ?? harness.models[0]
        return ModelBundle(modelId: id, version: "1.0.0", role: .asr, runtime: .onnx,
                           directoryURL: harness.directory(model))
    }

    func test_k32_loadedStateTracksOutstandingTokenCount() async throws {
        let (harness, manager) = try await downloaded(["use-a"])
        let token = try await manager.beginUse([bundle(harness, "use-a")])
        let between = await manager.state(id: "use-a", version: "1.0.0")
        XCTAssertEqual(between, .loaded)
        await manager.endUse(token)
        let after = await manager.state(id: "use-a", version: "1.0.0")
        XCTAssertEqual(after, .downloaded)

        let first = try await manager.beginUse([bundle(harness, "use-a")])
        let second = try await manager.beginUse([bundle(harness, "use-a")])
        await manager.endUse(first)
        let stillLoaded = await manager.state(id: "use-a", version: "1.0.0")
        XCTAssertEqual(stillLoaded, .loaded, "счётчик, не флаг: loaded до второго endUse")
        await manager.endUse(second)
        let released = await manager.state(id: "use-a", version: "1.0.0")
        XCTAssertEqual(released, .downloaded)
    }

    func test_k33_beginUseAtomicNotDownloadedRejectsWholeSetNamesOffender() async throws {
        let (harness, manager) = try await downloaded(["ready-a"], available: ["missing-b"])
        do {
            _ = try await manager.beginUse([bundle(harness, "ready-a"), bundle(harness, "missing-b")])
            XCTFail("ожидался notDownloaded")
        } catch let error as ModelCatalogError {
            XCTAssertEqual(error, .notDownloaded(modelId: "missing-b", version: "1.0.0"))
        }
        let readyState = await manager.state(id: "ready-a", version: "1.0.0")
        XCTAssertEqual(readyState, .downloaded, "готовый бандл набора не помечен")
    }

    func test_k34_endUseIdempotentOnDoubleOrUnknownTokenAndDistinguishesTwoTokens() async throws {
        let (harness, manager) = try await downloaded(["idem-a"])
        let token = try await manager.beginUse([bundle(harness, "idem-a")])
        await manager.endUse(token)
        await manager.endUse(token)
        await manager.endUse(ModelUseToken(rawValue: UUID()))
        let afterA = await manager.state(id: "idem-a", version: "1.0.0")
        XCTAssertEqual(afterA, .downloaded, "повторное и чужое погашение — без эффекта")

        let first = try await manager.beginUse([bundle(harness, "idem-a")])
        let second = try await manager.beginUse([bundle(harness, "idem-a")])
        await manager.endUse(first)
        await manager.endUse(first)
        let afterDouble = await manager.state(id: "idem-a", version: "1.0.0")
        XCTAssertEqual(afterDouble, .loaded, "повтор endUse(t1) не гасит счётчик ещё раз")
        await manager.endUse(second)
        let afterSecond = await manager.state(id: "idem-a", version: "1.0.0")
        XCTAssertEqual(afterSecond, .downloaded)
    }

    func test_k35_loadedNotRestoredAfterProcessRestart() async throws {
        let (harness, manager) = try await downloaded(["restart-a"])
        _ = try await manager.beginUse([bundle(harness, "restart-a")])
        let loaded = await manager.state(id: "restart-a", version: "1.0.0")
        XCTAssertEqual(loaded, .loaded, "вектор: расписка не погашена")
        let restarted = try harness.makeManager()
        let state = await restarted.state(id: "restart-a", version: "1.0.0")
        XCTAssertEqual(state, .downloaded, "новый экземпляр вычисляет по диску; расписки не восстановлены")
    }

    func test_k36_targetImportsNoInferenceFrameworks() throws {
        let sources = try ModelManagerSources.files()
        XCTAssertFalse(sources.isEmpty, "вектор непустоты: исходники ModelManager найдены")
        var imports = Set<String>()
        for source in sources {
            let code = ModelManagerSources.code(source.text)
            for line in code.components(separatedBy: "\n") where line.hasPrefix("import ") {
                imports.insert(String(line.dropFirst("import ".count)))
            }
            for forbidden in ["CoreML", "onnxruntime", "ONNXRuntime", "EngineKit", "MLModel"] {
                XCTAssertFalse(code.contains(forbidden), "\(source.name): \(forbidden)")
            }
        }
        XCTAssertEqual(imports, ["Foundation", "DomainCore", "FoundationNetworking"],
                       "только Foundation, DomainCore и FoundationNetworking (под #if canImport)")
    }

    func test_k44_foundationNetworkingImportedOnlyUnderCanImport() throws {
        let sources = try ModelManagerSources.files()
        var guarded = 0
        for source in sources {
            let lines = source.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line == "import FoundationNetworking" {
                XCTAssertGreaterThan(index, 0)
                XCTAssertEqual(lines[max(0, index - 1)], "#if canImport(FoundationNetworking)",
                               "\(source.name): импорт FoundationNetworking — только под #if canImport")
                guarded += 1
            }
        }
        XCTAssertGreaterThan(guarded, 0, "вектор непустоты: условный импорт в модуле есть")
    }
}
