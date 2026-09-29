//  К5 (вход Б), К10, К11 перечня MEE-429: `.manifest.json` на диске — чужой или отсутствующий
//  `schemaVersion` и модель без записи в действующем каталоге (инв. 33).

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

extension CatalogParsingTests {

    /// Модель скачана настоящим `download` — `.manifest.json` записан самой реализацией.
    private func downloadedHarness() async throws -> DownloadedFixture {
        let model = TestModel.make(id: "disk-asr", files: [("m.bin", TestModel.bytes(50, seed: 4))])
        let harness = ModelHarness(models: [model])
        let manager = try harness.makeManager()
        try await manager.download(id: model.descriptor.id, version: model.descriptor.version)
        return DownloadedFixture(harness: harness, manager: manager, model: model)
    }

    private func overwriteManifest(_ harness: ModelHarness, _ model: TestModel,
                                   _ transform: (String) -> String) throws {
        let url = harness.directory(model).appendingPathComponent(".manifest.json")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        try Data(transform(text).utf8).write(to: url)
    }

    func test_k05b_manifestMissingSchemaVersionKeyGivesErrorState() async throws {
        let fixture = try await downloadedHarness()
        let harness = fixture.harness
        let model = fixture.model
        try overwriteManifest(harness, model) { $0.replacingOccurrences(of: ",\"schemaVersion\":1", with: "") }
        let restarted = try harness.makeManager()
        let state = await restarted.state(id: model.descriptor.id, version: model.descriptor.version)
        guard case .error(.manifestInvalid(let message)) = state else {
            return XCTFail("ожидалось error(manifestInvalid), получено \(state)")
        }
        XCTAssertTrue(message.contains("schemaVersion"), message)
    }

    func test_k11_manifestWithForeignSchemaVersionGivesErrorState() async throws {
        let fixture = try await downloadedHarness()
        let harness = fixture.harness
        let manager = fixture.manager
        let model = fixture.model
        let before = await manager.state(id: model.descriptor.id, version: model.descriptor.version)
        XCTAssertEqual(before, .downloaded, "вектор непустоты: до правки модель скачана")
        try overwriteManifest(harness, model) {
            $0.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        }
        let restarted = try harness.makeManager()
        let state = await restarted.state(id: model.descriptor.id, version: model.descriptor.version)
        guard case .error(.manifestInvalid(let message)) = state else {
            return XCTFail("ожидалось error(manifestInvalid), получено \(state)")
        }
        XCTAssertTrue(message.contains("2") && message.contains("1"), message)
    }

    // Имя — дословно по плану MEE-436 (дельта e793c0ea); длиннее line_length само по себе.
    // swiftlint:disable:next line_length
    func test_k10_orphanedManifestModelUsesManifestAsSourceOfTruthForStateDeleteInvisibleViaCatalogMethodsVisibleInDiskUsage()
        async throws {
        let fixture = try await downloadedHarness()
        let harness = fixture.harness
        let manager = fixture.manager
        let model = fixture.model
        let other = TestModel.make(id: "other-asr", files: [("o.bin", TestModel.bytes(8, seed: 5))])
        harness.transport.setContent(try DomainJSON.encode(ModelCatalogFile(
            schemaVersion: 1, generatedAt: Date(), models: [other.descriptor], profiles: [])),
            at: ModelHarness.catalogURL)
        try await manager.refreshCatalog()
        let id = model.descriptor.id
        let version = model.descriptor.version

        let listed = await manager.models().map(\.id)
        XCTAssertEqual(listed, ["other-asr"], "models() модель без записи не показывает")
        let looked = await manager.model(id: id, version: version)
        XCTAssertNil(looked, "model(id:version:) её не находит")
        let state = await manager.state(id: id, version: version)
        XCTAssertEqual(state, .downloaded, "state — по .manifest.json, не unknownModel")
        let usage = await manager.diskUsage()
        XCTAssertEqual(usage.map(\.modelId), [id], "diskUsage показывает её всегда")

        try await manager.delete(id: id, version: version)
        XCTAssertFalse(harness.exists(harness.directory(model)), "delete удалил файлы, не unknownModel")
        let usageAfter = await manager.diskUsage()
        XCTAssertTrue(usageAfter.isEmpty)
    }
}

struct DownloadedFixture {
    let harness: ModelHarness
    let manager: ModelCatalogManager
    let model: TestModel
}
