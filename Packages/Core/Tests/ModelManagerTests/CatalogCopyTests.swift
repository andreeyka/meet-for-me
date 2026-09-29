//  C-014 v7 (IR-141; MEE-459): встроенный профиль на несуществующую модель отвергает каталог
//  целиком (инв. 34) — при `refreshCatalog` и при старте; сохранённая копия дословно и выбор
//  при старте по `generatedAt` (инв. 28); встроенный `catalog.json` проходит инв. 34.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class CatalogCopyTests: XCTestCase {

    private func makeHarness() -> ModelHarness {
        let asr = TestModel.make(id: "cc-asr", files: [("a.bin", TestModel.bytes(16, seed: 9))])
        let vad = TestModel.make(id: "cc-vad", role: .vad, files: [("v.bin", TestModel.bytes(16, seed: 10))])
        return ModelHarness(models: [asr, vad], profiles: [testProfile(id: "cc", asr: "cc-asr", vad: "cc-vad")])
    }

    private func catalog(_ harness: ModelHarness, generatedAt: TimeInterval,
                         profiles: [TranscriptionProfile]? = nil) throws -> Data {
        try DomainJSON.encode(ModelCatalogFile(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: generatedAt),
                                               models: harness.models.map(\.descriptor),
                                               profiles: profiles ?? harness.profiles))
    }

    // MARK: - Инв. 34

    func test_inv34_fixtureProfileWithUnknownModelRejectedWholeNamesProfileAndModel() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let before = await manager.models()
        harness.transport.setContent(CatalogFixtures.profileWithUnknownModelJSON, at: ModelHarness.catalogURL)
        do {
            try await manager.refreshCatalog()
            XCTFail("каталог обязан быть отвергнут")
        } catch ModelCatalogError.manifestInvalid(let message) {
            XCTAssertTrue(message.contains("ru-default"), message)
            XCTAssertTrue(message.contains(CatalogFixtures.unknownModelId), message)
        }
        let after = await manager.models()
        XCTAssertEqual(after, before, "действующий не заменён (инв. 31)")
    }

    func test_inv34_everyRoleCheckedOnRefresh() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let dangling = [
            testProfile(id: "bad", asr: "cc-asr", vad: "no-vad"),
            testProfile(id: "bad", asr: "cc-asr", diarization: "no-diar"),
            testProfile(id: "bad", asr: "cc-asr", embedding: "no-emb")
        ]
        for profile in dangling {
            let missing = profile.vadModelId ?? profile.diarizationModelId ?? profile.embeddingModelId ?? ""
            harness.transport.setContent(try catalog(harness, generatedAt: 1_800_000_000, profiles: [profile]),
                                         at: ModelHarness.catalogURL)
            do {
                try await manager.refreshCatalog()
                XCTFail("\(missing): каталог обязан быть отвергнут")
            } catch ModelCatalogError.manifestInvalid(let message) {
                XCTAssertTrue(message.contains("bad") && message.contains(missing), message)
            }
        }
        let ids = await manager.profiles().map(\.id)
        XCTAssertEqual(ids, ["cc"], "в силе прежний каталог")
    }

    func test_inv34_bundledCatalogResourcePassesReaderWithAllProfileModels() throws {
        let data = try XCTUnwrap(ModelCatalogManager.builtInCatalogData())
        let file = try CatalogReader.catalog(from: data)
        XCTAssertFalse(file.profiles.isEmpty, "вектор: встроенный каталог несёт профиль")
        let ids = Set(file.models.map(\.id))
        for profile in file.profiles {
            XCTAssertTrue(ModelCatalogManager.modelIds(of: profile).allSatisfy(ids.contains), profile.id)
        }
    }

    // MARK: - Инв. 28: старт

    func test_inv28_startupPicksLaterGeneratedAtCopyOnTie() async throws {
        let harness = makeHarness()
        let builtIn = try catalog(harness, generatedAt: 1_800_000_000)
        let cases: [(copyAt: TimeInterval, expectCopy: Bool)] = [
            (1_700_000_000, false), (1_900_000_000, true), (1_800_000_000, true)
        ]
        for (copyAt, expectCopy) in cases {
            // Копия отличима по составу: в ней нет модели cc-vad и профиля.
            let copy = try DomainJSON.encode(ModelCatalogFile(
                schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: copyAt),
                models: [harness.models[0].descriptor], profiles: []))
            try harness.writeCachedCatalog(copy)
            let manager = try harness.makeManager(builtIn: builtIn)
            let count = await manager.models().count
            XCTAssertEqual(count, expectCopy ? 1 : 2, "копия \(copyAt) против встроенного 1_800_000_000")
        }
    }

    func test_inv28_unreadableOrRejectedCopyNotChosenAndLogged() async throws {
        let harness = makeHarness()
        let builtIn = try catalog(harness, generatedAt: 1_800_000_000)
        let rejected = try catalog(harness, generatedAt: 1_900_000_000,
                                   profiles: [testProfile(id: "bad", asr: "no-such")])
        for copy in [Data("{".utf8), rejected] {
            harness.logged.update { $0 = [] }
            try harness.writeCachedCatalog(copy)
            let manager = try harness.makeManager(builtIn: builtIn)
            let ids = await manager.profiles().map(\.id)
            XCTAssertEqual(ids, ["cc"], "действует встроенный")
            XCTAssertEqual(harness.logged.value.count, 1, "отказ копии записан в лог")
        }
        let bothRejected = try harness.makeManager(builtIn: rejected)
        let models = await bothRejected.models()
        XCTAssertTrue(models.isEmpty, "обе копии отвергнуты — пустой каталог")
    }

    func test_inv28_acceptedCatalogStoredVerbatimRejectedNotStored() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let text = try XCTUnwrap(String(bytes: try catalog(harness, generatedAt: 1_900_000_000), encoding: .utf8))
        let withUnknownKey = "\"futureKey\":{\"x\":[1]},\"schemaVersion\""
        let served = Data(text.replacingOccurrences(of: "\"schemaVersion\"", with: withUnknownKey).utf8)
        harness.transport.setContent(served, at: ModelHarness.catalogURL)
        try await manager.refreshCatalog()
        let url = ModelCatalogManager.cachedCatalogURL(root: harness.root)
        XCTAssertEqual(try Data(contentsOf: url), served, "байты как пришли, с неизвестным ключом")

        harness.transport.setContent(CatalogFixtures.profileWithUnknownModelJSON, at: ModelHarness.catalogURL)
        _ = try? await manager.refreshCatalog()
        XCTAssertEqual(try Data(contentsOf: url), served, "отвергнутый не сохраняется")
    }
}
