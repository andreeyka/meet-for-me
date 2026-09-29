//  К69–К72 перечня MEE-429 (вторая поправка `2cb42043`; уточнения C-014 v7 от 29.09):
//  каждая роль защищает свою версию независимо от готовности `asr`; неготовая модель инв. 33;
//  одна запись в лог на отвергнутую копию; пустая строка в роли — обычный `id`.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

extension ClarificationsTests {

    // MARK: - К69

    func test_k69_eachRoleProtectsItsNewestReadyVersionEvenWhenAsrNotReady() async throws {
        let roles: [ModelRole] = [.vad, .diarization, .embedding]
        for role in roles {
            let asr = model("a", seed: 40)
            let current = model("v", "1.0.0", role: role, seed: 41)
            let older = model("v", "0.9.0", role: role, seed: 42)
            let profile = testProfile(id: "p", asr: "a", vad: role == .vad ? "v" : nil,
                                      diarization: role == .diarization ? "v" : nil,
                                      embedding: role == .embedding ? "v" : nil)
            let harness = ModelHarness(models: [asr, current, older], profiles: [profile])
            let manager = try harness.makeManager()
            try await manager.download(id: "v", version: "1.0.0")
            try await manager.download(id: "v", version: "0.9.0")
            let asrState = await manager.state(id: "a", version: "1.0.0")
            XCTAssertEqual(asrState, .available, "\(role): вектор — asr не готова")
            await expectCatalogError(.notDownloaded(modelId: "a", version: "1.0.0")) {
                _ = try await manager.resolve(profileId: "p")
            }
            await expectCatalogError(.modelInUseByProfile(modelId: "v", profileIds: ["p"])) {
                try await manager.delete(id: "v", version: "1.0.0")
            }
            XCTAssertTrue(harness.exists(harness.directory(current).appendingPathComponent("m.bin")), "\(role)")
            try await manager.delete(id: "v", version: "0.9.0")   // защищена только новейшая готовая
        }
    }

    // MARK: - К70

    func test_k70_unreadyDiskOnlyModelNamedByManifestDescriptorNotUnknownModel() async throws {
        let target = TestModel.make(id: "m", version: "1.2.0", files: [("one.bin", TestModel.bytes(20, seed: 43)),
                                                                        ("two.bin", TestModel.bytes(20, seed: 44))])
        let other = model("other", seed: 45)
        let harness = ModelHarness(models: [target, other])
        let manager = try harness.makeManager()
        try await manager.saveProfile(testProfile(id: "up", asr: "m", builtIn: false))
        try await manager.download(id: "m", version: "1.2.0")
        harness.models = [other]
        harness.transport.setContent(try harness.catalogBytes(), at: ModelHarness.catalogURL)
        try await manager.refreshCatalog()
        let directory = harness.directory(target)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("two.bin"))
        let manifest = try CatalogReader.manifest(from: Data(contentsOf: ModelDisk.manifestURL(in: directory)))

        let missing = try await manager.missingModels(profileId: "up")
        XCTAssertEqual(missing, [manifest.descriptor], "дескриптор из .manifest.json")
        await expectCatalogError(.notDownloaded(modelId: "m", version: "1.2.0")) {
            _ = try await manager.resolve(profileId: "up")
        }

        // Различающий: на диске `m` нет вовсе — `unknownModel` (К59).
        try FileManager.default.removeItem(at: directory)
        await expectCatalogError(.unknownModel(id: "m", version: "")) {
            _ = try await manager.missingModels(profileId: "up")
        }
    }

    // MARK: - К71

    func test_k71_oneLogEntryPerRejectedCopyNoneForChosenOrOlderValidCopy() async throws {
        let asr = model("a", seed: 46)
        let vad = model("b", role: .vad, seed: 47)
        let harness = ModelHarness(models: [asr, vad], profiles: [testProfile(id: "p", asr: "a")])
        func file(_ at: TimeInterval, _ models: [TestModel], _ profiles: [TranscriptionProfile]) throws -> Data {
            try DomainJSON.encode(ModelCatalogFile(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: at),
                                                   models: models.map(\.descriptor), profiles: profiles))
        }
        let builtIn = try file(1_800_000_000, [asr, vad], harness.profiles)
        struct Run {
            let name: String
            let copy: Data
            let entries: Int
        }
        let runs = [
            Run(name: "(iv) не читается", copy: Data("{\"schemaVersion\":1,\"schemaVersion\":1}".utf8), entries: 1),
            Run(name: "(v) инв. 34", copy: try file(1_900_000_000, [asr], [testProfile(id: "bad", asr: "none")]),
                entries: 1),
            Run(name: "(i) выбрана", copy: try file(1_900_000_000, [asr], []), entries: 0),
            Run(name: "(ii) старше, годна", copy: try file(1_700_000_000, [asr], []), entries: 0)
        ]
        for run in runs {
            harness.logged.update { $0 = [] }
            try harness.writeCachedCatalog(run.copy)
            _ = try harness.makeManager(builtIn: builtIn)
            XCTAssertEqual(harness.logged.value.count, run.entries, run.name)
        }
    }

    // MARK: - К72

    func test_k72_emptyStringRoleIsOrdinaryUnknownIdNilIsNot() async throws {
        let asr = model("a", seed: 48)
        let harness = ModelHarness(models: [asr], profiles: [testProfile(id: "p", asr: "a")])
        let manager = try harness.makeManager()
        await expectCatalogError(.unknownModel(id: "", version: "")) {
            try await manager.saveProfile(testProfile(id: "u", asr: "a", vad: "", builtIn: false))
        }
        let afterEmpty = await manager.profiles().map(\.id)
        XCTAssertFalse(afterEmpty.contains("u"), "А: не сохранён")
        try await manager.saveProfile(testProfile(id: "u", asr: "a", builtIn: false))   // Б: nil — не отказ

        let before = await manager.profiles().filter(\.isBuiltIn)
        func catalog(diarization: String?) throws -> Data {
            try DomainJSON.encode(ModelCatalogFile(
                schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 1_900_000_000), models: [asr.descriptor],
                profiles: [testProfile(id: "bp", asr: "a", diarization: diarization)]))
        }
        harness.transport.setContent(try catalog(diarization: ""), at: ModelHarness.catalogURL)
        do {
            try await manager.refreshCatalog()
            XCTFail("В: пустая строка — несуществующий id")
        } catch ModelCatalogError.manifestInvalid(let message) {
            XCTAssertTrue(message.contains("bp"), message)
        }
        let unchanged = await manager.profiles().filter(\.isBuiltIn)
        XCTAssertEqual(unchanged, before, "В: действующий не заменён")
        harness.transport.setContent(try catalog(diarization: nil), at: ModelHarness.catalogURL)
        try await manager.refreshCatalog()
        let accepted = await manager.profiles().filter(\.isBuiltIn).map(\.id)
        XCTAssertEqual(accepted, ["bp"], "В: с nil — принят")
    }
}
