//  К12–К14 перечня MEE-429 (группа В): `DomainJSON` на чтении `catalog.json` и на записи
//  `.manifest.json` — целые поля через `decodeBounded`, грамматика дат, неизвестные ключи.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

extension CatalogParsingTests {

    private var validText: String {
        String(bytes: CatalogFixtures.validCatalogJSON, encoding: .utf8) ?? ""
    }

    func test_k12_integerFieldsAcceptFloatLiteralForm() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let text = validText
            .replacingOccurrences(of: "\"minRAMGB\": 8", with: "\"minRAMGB\": 8.0")
            .replacingOccurrences(of: "\"sizeBytes\": 236978176", with: "\"sizeBytes\": 2.36978176e8")
            .replacingOccurrences(of: "\"minSegmentMs\": 500", with: "\"minSegmentMs\": 5e2")
        XCTAssertTrue(text.contains("2.36978176e8") && text.contains("8.0"), "вектор непустоты: литералы подменены")
        let error = await refresh(manager, harness: harness, with: Data(text.utf8))
        XCTAssertNil(error)
        let found = await manager.model(id: CatalogFixtures.asrModelId, version: "3.0.0")
        let model = try XCTUnwrap(found)
        XCTAssertEqual(model.minRAMGB, 8)
        XCTAssertEqual(model.sizeBytes, 236_978_176)
        let profiles = await manager.profiles()
        let profile = try XCTUnwrap(profiles.first { $0.id == "ru-default" })
        XCTAssertEqual(profile.diarization.minSegmentMs, 500)
    }

    func test_k13_generatedAtWiderReadGrammarThenManifestWrittenCompactSortedRoundTrips() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        for stamp in ["2026-09-11T00:00:00Z", "2026-09-11T00:00:00.000+03:00"] {
            let text = validText.replacingOccurrences(of: "2026-09-11T00:00:00.000Z", with: stamp)
            XCTAssertTrue(text.contains(stamp))
            let error = await refresh(manager, harness: harness, with: Data(text.utf8))
            XCTAssertNil(error, "generatedAt «\(stamp)» читается")
        }

        // Запись: .manifest.json после download — компактный, ключи по порядку, round-trip.
        let model = TestModel.make(id: "write-asr", files: [("w.bin", TestModel.bytes(30, seed: 6))])
        let writer = ModelHarness(models: [model])
        let writerManager = try writer.makeManager()
        try await writerManager.download(id: model.descriptor.id, version: model.descriptor.version)
        let bytes = try Data(contentsOf: writer.directory(model).appendingPathComponent(".manifest.json"))
        let text = String(bytes: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("\n") || text.contains(": "), "компактно: \(text)")
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"descriptor\"")).lowerBound,
                          try XCTUnwrap(text.range(of: "\"schemaVersion\"")).lowerBound, "ключи отсортированы")
        let decoded = try DomainJSON.decode(ModelManifestFile.self, from: bytes)
        XCTAssertEqual(decoded, ModelManifestFile(schemaVersion: 1, descriptor: model.descriptor))
        XCTAssertEqual(try DomainJSON.encode(decoded), bytes, "байты — канонический вид DomainJSON")

        // Отрицательный вектор decodeBounded (по аналогии): дробное в целом поле — отказ.
        let fractional = validText.replacingOccurrences(of: "\"minRAMGB\": 8", with: "\"minRAMGB\": 8.5")
        let error = await refresh(manager, harness: harness, with: Data(fractional.utf8))
        let message = manifestInvalidMessage(error)
        XCTAssertTrue(message.contains("minRAMGB"), message)
    }

    func test_k14_unknownKeysIgnoredAtAllLevels() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let text = validText
            .replacingOccurrences(of: "\"schemaVersion\": 1,",
                                  with: "\"schemaVersion\": 1, \"futureTop\": {\"x\": [1]},")
            .replacingOccurrences(of: "\"role\": \"asr\",", with: "\"role\": \"asr\", \"futureModelField\": true,")
            .replacingOccurrences(of: "\"sizeBytes\": 262144}", with: "\"sizeBytes\": 262144, \"extra\": \"x\"}")
        XCTAssertTrue(text.contains("futureTop") && text.contains("futureModelField") && text.contains("\"extra\""))
        let error = await refresh(manager, harness: harness, with: Data(text.utf8))
        XCTAssertNil(error, "лишние поля не вызывают отказа")
        let ids = await manager.models().map(\.id)
        XCTAssertEqual(ids, [CatalogFixtures.asrModelId, CatalogFixtures.vadModelId])
    }
}

// MARK: - К3, доп. векторы через refreshCatalog (возврат РП `e64cbd81`, желательное)

extension CatalogParsingTests {

    func test_k03b_sha256WrongLengthAndUppercaseRejectedThroughRefresh() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let text = String(bytes: CatalogFixtures.validCatalogJSON, encoding: .utf8) ?? ""
        let valid = CatalogFixtures.validVocabSha256
        for bad in [valid + "1", String(repeating: "A", count: 64)] {
            XCTAssertTrue(text.contains(valid), "вектор: подменяемая строка есть")
            let error = await refresh(manager, harness: harness,
                                      with: Data(text.replacingOccurrences(of: valid, with: bad).utf8))
            let message = manifestInvalidMessage(error)
            XCTAssertTrue(message.contains("vocab.txt") && message.contains(bad), message)
            let ids = await manager.models().map(\.id)
            XCTAssertEqual(ids, ["base-asr"], "каталог отвергнут целиком")
        }
    }
}
