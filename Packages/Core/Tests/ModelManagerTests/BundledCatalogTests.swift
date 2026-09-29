//  Z7 (MEE-452): встроенный `catalog.json` — реальная модель GigaAM, без заглушек.
//  Критерии 1–5 (IR-152, п. 3): значения файла, инв. 1 и 34 C-014, `missingModels`/`resolve` до загрузки.

import XCTest
import DomainCore
@testable import ModelManager

final class BundledCatalogTests: XCTestCase {

    private static let revision = "6888903da215c7735f51101d939f3bfa679fb2b8"

    private func bundledData() throws -> Data {
        try XCTUnwrap(ModelCatalogManager.builtInCatalogData())
    }

    private func bundledCatalog() throws -> ModelCatalogFile {
        try CatalogReader.catalog(from: bundledData())
    }

    func test_z7_noPlaceholderHostsOrZeroHashes() throws {
        let text = try XCTUnwrap(String(data: bundledData(), encoding: .utf8))
        XCTAssertFalse(text.contains("cdn.example"))
        XCTAssertFalse(text.contains(String(repeating: "0", count: 64)))
        XCTAssertFalse(text.contains(String(repeating: "1", count: 64)))
    }

    func test_z7_gigaamSizesAndFilesMatchRevision() throws {
        let file = try bundledCatalog()
        let model = try XCTUnwrap(file.models.first { $0.id == "gigaam-v3-e2e-ctc-int8" })
        XCTAssertEqual(model.sizeBytes, 319_871_127)
        XCTAssertEqual(model.files.map(\.sizeBytes).reduce(0, +), model.sizeBytes, "инв. 1")
        XCTAssertEqual(model.files.map(\.name), ["model.int8.onnx", "tokens.txt"])
        XCTAssertEqual(model.files.map(\.sizeBytes), [319_869_121, 2006])
        XCTAssertEqual(model.files.map(\.sha256), [
            "0aacb41f70f0f5aaac4b45dd430337b9e16b180f22c72af04db8516e7609c3c0",
            "f8eb9b115e2748db9c40a5897cae11dd0678cc0b40fd7e25f8c43b3bf28715e4"
        ])
    }

    func test_z7_urlsPinToFullCommitNotMain() throws {
        let model = try XCTUnwrap(try bundledCatalog().models.first)
        let prefix = "https://huggingface.co/Smirnov75/GigaAM-v3-sherpa-onnx/resolve/\(Self.revision)/"
        XCTAssertEqual(model.files.map(\.url.absoluteString), [
            prefix + "gigaam_v3_e2e_ctc_int8.onnx",
            prefix + "gigaam_v3_e2e_ctc_tokens.txt"
        ])
        for file in model.files {
            XCTAssertNotNil(file.url.absoluteString.range(of: "/resolve/[0-9a-f]{40}/", options: .regularExpression))
            XCTAssertFalse(file.url.absoluteString.contains("/main/"))
        }
    }

    func test_z7_ruDefaultHasOnlyAsrAndPassesInvariant34() throws {
        let file = try bundledCatalog()
        let profile = try XCTUnwrap(file.profiles.first { $0.id == "ru-default" })
        XCTAssertEqual(profile.asrModelId, "gigaam-v3-e2e-ctc-int8")
        XCTAssertNil(profile.vadModelId)
        XCTAssertNil(profile.diarizationModelId)
        XCTAssertNil(profile.embeddingModelId)
        let ids = Set(file.models.map(\.id))
        for each in file.profiles {
            XCTAssertTrue(ModelCatalogManager.modelIds(of: each).allSatisfy(ids.contains), each.id)
        }
    }

    func test_z7_missingModelsReturnsGigaamAndResolveIsNotDownloadedBeforeDownload() async throws {
        let manager = try ModelHarness(models: []).makeManager(builtIn: bundledData())
        let missing = try await manager.missingModels(profileId: "ru-default")
        XCTAssertEqual(missing.map(\.id), ["gigaam-v3-e2e-ctc-int8"])
        do {
            _ = try await manager.resolve(profileId: "ru-default")
            XCTFail("модель не скачана — ожидался notDownloaded")
        } catch let error as ModelCatalogError {
            XCTAssertEqual(error, .notDownloaded(modelId: "gigaam-v3-e2e-ctc-int8", version: "3.0.0"))
        }
    }
}
