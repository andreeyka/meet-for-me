//  К56–К58 перечня MEE-429 (поправка `d999d708`, C-014 v7; MEE-459): сохранённая копия
//  `catalog.json` дословно и только после приёма (инв. 28); выбор при старте по `generatedAt`
//  (инв. 28, 34); встроенный профиль на несуществующую модель отвергает каталог (инв. 34).
//  Плюс: встроенный ресурс `catalog.json` сам проходит инв. 34.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class CatalogCopyTests: XCTestCase {

    private struct Rejection {
        let missing: String
        let profileId: String
        let bytes: Data
    }

    private func makeHarness() -> ModelHarness {
        let asr = TestModel.make(id: "cc-asr", files: [("a.bin", TestModel.bytes(16, seed: 9))])
        let vad = TestModel.make(id: "cc-vad", role: .vad, files: [("v.bin", TestModel.bytes(16, seed: 10))])
        return ModelHarness(models: [asr, vad], profiles: [testProfile(id: "cc", asr: "cc-asr", vad: "cc-vad")])
    }

    private func catalog(_ harness: ModelHarness, generatedAt: TimeInterval,
                         models: [ModelDescriptor]? = nil, profiles: [TranscriptionProfile]? = nil) throws -> Data {
        try DomainJSON.encode(ModelCatalogFile(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: generatedAt),
                                               models: models ?? harness.models.map(\.descriptor),
                                               profiles: profiles ?? harness.profiles))
    }

    private func refresh(_ manager: ModelCatalogManager, _ harness: ModelHarness,
                         with data: Data) async -> ModelCatalogError? {
        harness.transport.setContent(data, at: ModelHarness.catalogURL)
        do {
            try await manager.refreshCatalog()
            return nil
        } catch {
            return error as? ModelCatalogError ?? .downloadFailed(message: "не ModelCatalogError: \(error)")
        }
    }

    // MARK: - К56

    func test_k56_acceptedCatalogStoredVerbatimRejectedOrUnreachableLeaveCopyByteForByte() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        // А: не канонический вид — пробелы, ключи не по порядку, неизвестный ключ сверху и в записи модели.
        let text = try XCTUnwrap(String(bytes: CatalogFixtures.validCatalogJSON, encoding: .utf8))
            .replacingOccurrences(of: "{\n  \"schemaVersion\"",
                                  with: "{\n  \"futureTop\": [1, {\"a\": 2}],\n  \"schemaVersion\"")
            .replacingOccurrences(of: "\"id\": \"silero-vad\",",
                                  with: "\"id\": \"silero-vad\", \"futureInModel\": true,")
        XCTAssertTrue(text.contains("futureTop") && text.contains("futureInModel"), "вектор: оба неизвестных ключа")
        let served = Data(text.utf8)
        let accepted = await refresh(manager, harness, with: served)
        XCTAssertNil(accepted)
        let url = ModelCatalogManager.cachedCatalogURL(root: harness.root)
        XCTAssertEqual(try Data(contentsOf: url), served, "копия побайтно равна ответу CDN")

        // Б: отвергнутый по инв. 2, 3, 15, 30, 34 — копия прежняя.
        let rejected = [CatalogFixtures.duplicateModelPairJSON, CatalogFixtures.malformedSha256JSON,
                        CatalogFixtures.unknownSchemaVersionJSON, CatalogFixtures.nonBuiltInProfileJSON,
                        CatalogFixtures.profileWithUnknownModelJSON]
        for (index, bytes) in rejected.enumerated() {
            let error = await refresh(manager, harness, with: bytes)
            guard case .manifestInvalid? = error else {
                XCTFail("прогон \(index): ожидался manifestInvalid, получено \(String(describing: error))")
                continue
            }
            XCTAssertEqual(try Data(contentsOf: url), served, "прогон \(index): копия не заменена")
        }

        // В: CDN недоступен (К9) — копия прежняя.
        harness.transport.script(ModelHarness.catalogURL, [.fail])
        do {
            try await manager.refreshCatalog()
            XCTFail("ожидался manifestUnreachable")
        } catch ModelCatalogError.manifestUnreachable {
        }
        XCTAssertEqual(try Data(contentsOf: url), served)
    }

    // MARK: - К57

    func test_k57_startupPicksLaterGeneratedAtCopyOnTieUnreadableOrInvalidCopyNotChosenAndLogged() async throws {
        let harness = makeHarness()
        let builtIn = try catalog(harness, generatedAt: 1_800_000_000)
        // Копия отличима по составу: одна модель и ни одного профиля.
        func copy(_ at: TimeInterval, profiles: [TranscriptionProfile] = []) throws -> Data {
            try catalog(harness, generatedAt: at, models: [harness.models[0].descriptor], profiles: profiles)
        }
        let unreadable = try XCTUnwrap(String(bytes: try copy(1_900_000_000), encoding: .utf8))
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1")
        XCTAssertTrue(unreadable.contains("\"schemaVersion\":1,\"schemaVersion\":1"), "вектор: повторяющийся ключ")
        let dangling = [testProfile(id: "bad", asr: "no-such")]
        let runs: [(copy: Data, expectCopy: Bool)] = [
            (try copy(1_900_000_000), true),                                  // (i) копия позже
            (try copy(1_700_000_000), false),                                 // (ii) встроенный позже
            (try copy(1_800_000_000), true),                                  // (iii) равны — копия
            (Data(unreadable.utf8), false),                                   // (iv) не читается
            (try copy(1_900_000_000, profiles: dangling), false)              // (v) инв. 34
        ]
        for (index, run) in runs.enumerated() {
            harness.logged.update { $0 = [] }
            try harness.writeCachedCatalog(run.copy)
            let manager = try harness.makeManager(builtIn: builtIn)
            let models = await manager.models().count
            let profiles = await manager.profiles().map(\.id)
            XCTAssertEqual(models, run.expectCopy ? 1 : 2, "прогон \(index + 1)")
            XCTAssertEqual(profiles, run.expectCopy ? [] : ["cc"], "прогон \(index + 1)")
            XCTAssertEqual(harness.logged.value.count, index >= 3 ? 1 : 0, "прогон \(index + 1): отказ копии — в лог")
        }
        let bothRejected = try harness.makeManager(builtIn: try copy(1, profiles: dangling))
        let models = await bothRejected.models()
        XCTAssertTrue(models.isEmpty, "обе отвергнуты — пустой каталог")
    }

    // MARK: - К58

    func test_k58_builtInProfileOnMissingModelInAnyRoleRejectsWholeCatalogAnyVersionAccepted() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let url = ModelCatalogManager.cachedCatalogURL(root: harness.root)
        let copyBefore = try catalog(harness, generatedAt: 1_800_000_000)
        let seeded = await refresh(manager, harness, with: copyBefore)
        XCTAssertNil(seeded, "вектор: копия C₀ принята")
        let modelsBefore = await manager.models()
        let profilesBefore = await manager.profiles()
        let roles: [(missing: String, profile: TranscriptionProfile)] = [
            ("no-asr", testProfile(id: "bp", asr: "no-asr")),
            ("no-vad", testProfile(id: "bp", asr: "cc-asr", vad: "no-vad")),
            ("no-diar", testProfile(id: "bp", asr: "cc-asr", diarization: "no-diar")),
            ("no-emb", testProfile(id: "bp", asr: "cc-asr", embedding: "no-emb"))
        ]
        var cases = try roles.map { role in
            Rejection(missing: role.missing, profileId: "bp",
                      bytes: try catalog(harness, generatedAt: 1_900_000_000, profiles: [role.profile]))
        }
        cases.append(Rejection(missing: CatalogFixtures.unknownModelId, profileId: "ru-default",
                               bytes: CatalogFixtures.profileWithUnknownModelJSON))
        for run in cases {
            let error = await refresh(manager, harness, with: run.bytes)
            guard case .manifestInvalid(let message)? = error else {
                XCTFail("\(run.missing): ожидался manifestInvalid, получено \(String(describing: error))")
                continue
            }
            XCTAssertTrue(message.contains(run.profileId) && message.contains(run.missing), message)
            let models = await manager.models()
            let profiles = await manager.profiles()
            XCTAssertEqual(models, modelsBefore, "\(run.missing): действующий не заменён (инв. 31)")
            XCTAssertEqual(profiles, profilesBefore, run.missing)
            XCTAssertEqual(try Data(contentsOf: url), copyBefore, "\(run.missing): копия не заменена")
        }

        // Различающий: модель профиля есть в каталоге в другой версии — принят («в любой версии»).
        let other = TestModel.make(id: "cc-vad", version: "9.1.0-rc.1", role: .vad,
                                   files: [("v.bin", TestModel.bytes(16, seed: 11))])
        let anyVersion = try catalog(harness, generatedAt: 1_900_000_000,
                                     models: [harness.models[0].descriptor, other.descriptor])
        let acceptedAnyVersion = await refresh(manager, harness, with: anyVersion)
        XCTAssertNil(acceptedAnyVersion, "«в любой версии»")
    }

    // MARK: - Встроенный ресурс

    func test_bundledCatalogResourcePassesInvariant34() throws {
        let data = try XCTUnwrap(ModelCatalogManager.builtInCatalogData())
        let file = try CatalogReader.catalog(from: data)
        XCTAssertFalse(file.profiles.isEmpty, "вектор: встроенный каталог несёт профиль")
        let ids = Set(file.models.map(\.id))
        for profile in file.profiles {
            XCTAssertTrue(ModelCatalogManager.modelIds(of: profile).allSatisfy(ids.contains), profile.id)
        }
    }
}
