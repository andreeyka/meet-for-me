//  К1–К9 перечня MEE-429 (план MEE-436, группы А/Б): структурные факты каталога, разбор
//  `catalog.json` и целостность действующего каталога. Байты фикстур идут в `refreshCatalog`
//  через тестовый `ModelFileTransport` — тот же шов, что у файлов моделей.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class CatalogParsingTests: XCTestCase {

    /// Стенд с одной моделью и одним профилем в действующем (встроенном) каталоге.
    func makeHarness() -> ModelHarness {
        let model = TestModel.make(id: "base-asr", files: [("a.bin", TestModel.bytes(40, seed: 3))])
        return ModelHarness(models: [model], profiles: [testProfile(id: "base", asr: "base-asr")])
    }

    /// `refreshCatalog` на заданных байтах; возвращает брошенную `ModelCatalogError` либо `nil`.
    func refresh(_ manager: ModelCatalogManager, harness: ModelHarness, with data: Data) async -> ModelCatalogError? {
        harness.transport.setContent(data, at: ModelHarness.catalogURL)
        do {
            try await manager.refreshCatalog()
            return nil
        } catch let error as ModelCatalogError {
            return error
        } catch {
            XCTFail("наружу вышла не ModelCatalogError: \(error)")
            return nil
        }
    }

    func manifestInvalidMessage(_ error: ModelCatalogError?, file: StaticString = #filePath,
                                line: UInt = #line) -> String {
        guard case .manifestInvalid(let message)? = error else {
            XCTFail("ожидался manifestInvalid, получено \(String(describing: error))", file: file, line: line)
            return ""
        }
        return message
    }

    // MARK: - А. К1–К3

    func test_k01_descriptorSizeBytesEqualsSumOfFileSizes() throws {
        let builtIn = try XCTUnwrap(ModelCatalogManager.builtInCatalogData(), "встроенная копия catalog.json есть")
        let builtInCatalog = try CatalogReader.catalog(from: builtIn)
        XCTAssertFalse(builtInCatalog.models.isEmpty, "вектор непустоты: встроенный каталог несёт модели")
        for catalog in [builtInCatalog, CatalogFixtures.validCatalog] {
            for model in catalog.models {
                XCTAssertEqual(model.sizeBytes, model.files.reduce(0) { $0 + $1.sizeBytes },
                               "инв. 1: sizeBytes \(model.id) — сумма files[].sizeBytes")
            }
        }
        XCTAssertEqual(CatalogFixtures.validCatalog.models.count, 2)
    }

    func test_k02_duplicateIdVersionPairRejectedAsManifestInvalidNamesIdAndVersion() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let before = await manager.models()
        let error = await refresh(manager, harness: harness, with: CatalogFixtures.duplicateModelPairJSON)
        let message = manifestInvalidMessage(error)
        XCTAssertTrue(message.contains("gigaam-v3-e2e-ctc-int8"), message)
        XCTAssertTrue(message.contains("3.0.0"), message)
        let after = await manager.models()
        XCTAssertEqual(after, before, "каталог отвергнут целиком — действует прежний")
    }

    func test_k03_malformedSha256FormRejectedMessageNamesIdVersionFilenameAndString() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let error = await refresh(manager, harness: harness, with: CatalogFixtures.malformedSha256JSON)
        let message = manifestInvalidMessage(error)
        for part in ["gigaam-v3-e2e-ctc-int8", "3.0.0", "vocab.txt", CatalogFixtures.malformedSha256] {
            XCTAssertTrue(message.contains(part), "message называет «\(part)»: \(message)")
        }
        let ids = await manager.models().map(\.id)
        XCTAssertEqual(ids, ["base-asr"], "каталог отвергнут целиком")
        XCTAssertFalse(CatalogReader.isSHA256(String(repeating: "A", count: 64)), "заглавные — не форма")
        XCTAssertFalse(CatalogReader.isSHA256(String(repeating: "a", count: 65)), "65 символов — не форма")
        XCTAssertTrue(CatalogReader.isSHA256(String(repeating: "a", count: 64)))
    }

    // MARK: - Б. К4–К9

    func test_k04_schemaVersionCheckedBeforeFieldValidationMessageNamesBothVersions() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let error = await refresh(manager, harness: harness, with: CatalogFixtures.unknownSchemaVersionJSON)
        let message = manifestInvalidMessage(error)
        XCTAssertTrue(message.contains("schemaVersion 2"), message)
        XCTAssertTrue(message.contains("поддерживается 1"), message)
        XCTAssertFalse(message.contains("minChip") || message.contains("m9"), "не битое поле: \(message)")
    }

    func test_k05a_catalogMissingSchemaVersionKeyRejectedByRefresh() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let error = await refresh(manager, harness: harness, with: CatalogFixtures.missingSchemaVersionJSON)
        let message = manifestInvalidMessage(error)
        XCTAssertTrue(message.contains("schemaVersion"), message)
    }

    func test_k06_duplicateTopLevelKeyRejectedBeforeParsing() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let error = await refresh(manager, harness: harness, with: CatalogFixtures.duplicateKeyJSON)
        let message = manifestInvalidMessage(error)
        XCTAssertTrue(message.contains("generatedAt"), "отказ называет повторившийся ключ: \(message)")
        let ids = await manager.models().map(\.id)
        XCTAssertEqual(ids, ["base-asr"])
    }

    func test_k06_noJSONDecoderOrEncoderInModelManagerSources() throws {
        let sources = try ModelManagerSources.files()
        XCTAssertFalse(sources.isEmpty, "вектор непустоты: исходники ModelManager найдены")
        for source in sources {
            let code = ModelManagerSources.code(source.text)
            XCTAssertFalse(code.contains("JSONDecoder"), "\(source.name): JSONDecoder")
            XCTAssertFalse(code.contains("JSONEncoder"), "\(source.name): JSONEncoder")
        }
        XCTAssertTrue(sources.contains { $0.text.contains("DomainJSON.decode") }, "чтение — через DomainJSON")
    }

    func test_k07_nonBuiltInProfileRejectsWholeCatalog() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let error = await refresh(manager, harness: harness, with: CatalogFixtures.nonBuiltInProfileJSON)
        let message = manifestInvalidMessage(error)
        XCTAssertTrue(message.contains(CatalogFixtures.nonBuiltInProfileId), message)
        let ids = await manager.models().map(\.id)
        XCTAssertEqual(ids, ["base-asr"], "отвергнуты и описания моделей, не только профиль")
    }

    func test_k08_catalogUnchangedAfterRejectedRefresh() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let models = await manager.models()
        let profiles = await manager.profiles()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(profiles.count, 1)
        for rejected in [CatalogFixtures.unknownSchemaVersionJSON, CatalogFixtures.nonBuiltInProfileJSON] {
            let error = await refresh(manager, harness: harness, with: rejected)
            _ = manifestInvalidMessage(error)
            let modelsAfter = await manager.models()
            let profilesAfter = await manager.profiles()
            XCTAssertEqual(modelsAfter, models)
            XCTAssertEqual(profilesAfter, profiles)
        }
    }

    func test_k09_cdnUnreachableKeepsExistingCatalog() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        harness.transport.script(ModelHarness.catalogURL, [.fail])
        do {
            try await manager.refreshCatalog()
            XCTFail("ожидался manifestUnreachable")
        } catch ModelCatalogError.manifestUnreachable {
        } catch {
            XCTFail("ожидался manifestUnreachable, получено \(error)")
        }
        let ids = await manager.models().map(\.id)
        XCTAssertEqual(ids, ["base-asr"], "действующий каталог не стал пустым")
        let valid = await refresh(manager, harness: harness, with: CatalogFixtures.validCatalogJSON)
        XCTAssertNil(valid, "вектор непустоты: валидный каталог принимается")
        let refreshed = await manager.models().map(\.id)
        XCTAssertEqual(refreshed, [CatalogFixtures.asrModelId, CatalogFixtures.vadModelId])
    }
}
