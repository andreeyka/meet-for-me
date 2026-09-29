//  C-014 v7 (IR-141; MEE-459): версия для профиля и что она защищает — инв. 11 (по версии,
//  `modelInUse`), 13 (все четыре роли), 34 (пользовательский профиль на исчезнувшую модель),
//  35 (новейшая готовая по SemVer §11, модели инв. 33 участвуют).

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class VersionRulesTests: XCTestCase {

    private func model(_ id: String, _ version: String, role: ModelRole = .asr, seed: UInt8) -> TestModel {
        TestModel.make(id: id, version: version, role: role, files: [("m.bin", TestModel.bytes(24, seed: seed))])
    }

    // MARK: - Инв. 11 по версии

    func test_inv11_onlyResolvedVersionProtectedOlderAndUnfinishedDeletable() async throws {
        let old = model("vr-asr", "1.0.0", seed: 1)
        let current = model("vr-asr", "2.0.0", seed: 2)
        let unfinished = model("vr-asr", "3.0.0", seed: 3)
        let harness = ModelHarness(models: [old, current, unfinished], profiles: [testProfile(id: "p", asr: "vr-asr")])
        harness.transport.chunkSize = 8
        harness.transport.script(unfinished.url("m.bin"), [.dropAfter(bytes: 8)])
        let manager = try harness.makeManager()
        try await manager.download(id: "vr-asr", version: "1.0.0")
        try await manager.download(id: "vr-asr", version: "2.0.0")
        _ = try? await manager.download(id: "vr-asr", version: "3.0.0")
        let unfinishedState = await manager.state(id: "vr-asr", version: "3.0.0")
        XCTAssertEqual(unfinishedState, .paused(bytesOnDisk: 8), "вектор: 3.0.0 недокачана")

        await expectCatalogError(.modelInUseByProfile(modelId: "vr-asr", profileIds: ["p"])) {
            try await manager.delete(id: "vr-asr", version: "2.0.0")
        }
        try await manager.delete(id: "vr-asr", version: "1.0.0")
        try await manager.delete(id: "vr-asr", version: "3.0.0")
        for version in ["1.0.0", "3.0.0"] {
            let state = await manager.state(id: "vr-asr", version: version)
            XCTAssertEqual(state, .available, "\(version) удалена")
        }
        let kept = await manager.state(id: "vr-asr", version: "2.0.0")
        XCTAssertEqual(kept, .downloaded)
    }

    func test_inv11_loadedWithoutResolvingProfileThrowsModelInUseProfilesFirstWhenBoth() async throws {
        let free = model("vr-free", "1.0.0", seed: 4)
        let used = model("vr-used", "1.0.0", seed: 5)
        let harness = ModelHarness(models: [free, used], profiles: [testProfile(id: "p", asr: "vr-used")])
        let manager = try harness.makeManager()
        var bundles: [ModelBundle] = []
        for item in [free, used] {
            try await manager.download(id: item.descriptor.id, version: "1.0.0")
            bundles.append(ModelBundle(modelId: item.descriptor.id, version: "1.0.0", role: .asr, runtime: .onnx,
                                       directoryURL: harness.directory(item)))
        }
        let token = try await manager.beginUse(bundles)

        await expectCatalogError(.modelInUse(modelId: "vr-free", version: "1.0.0")) {
            try await manager.delete(id: "vr-free", version: "1.0.0")
        }
        await expectCatalogError(.modelInUseByProfile(modelId: "vr-used", profileIds: ["p"])) {
            try await manager.delete(id: "vr-used", version: "1.0.0")
        }
        let state = await manager.state(id: "vr-free", version: "1.0.0")
        XCTAssertEqual(state, .loaded, "ничего не удалено")
        XCTAssertTrue(harness.exists(harness.directory(free).appendingPathComponent("m.bin")))

        await manager.endUse(token)
        try await manager.delete(id: "vr-free", version: "1.0.0")
        let after = await manager.state(id: "vr-free", version: "1.0.0")
        XCTAssertEqual(after, .available, "вектор: после endUse удаляется")
    }

    // MARK: - Инв. 13: все четыре роли

    func test_inv13_saveProfileChecksAllFourRolesInOrderAndAcceptsDiskOnlyModel() async throws {
        let asr = model("r-asr", "1.0.0", seed: 6)
        let orphan = model("r-orphan", "1.0.0", role: .vad, seed: 7)
        let harness = ModelHarness(models: [asr, orphan])
        let manager = try harness.makeManager()
        try await manager.download(id: "r-orphan", version: "1.0.0")
        // Запись r-orphan исчезает из каталога — файлы и `.manifest.json` остаются (инв. 33).
        harness.models = [asr]
        harness.transport.setContent(try harness.catalogBytes(), at: ModelHarness.catalogURL)
        try await manager.refreshCatalog()

        let cases: [(TranscriptionProfile, String)] = [
            (testProfile(id: "u", asr: "x-asr", vad: "x-vad", builtIn: false), "x-asr"),
            (testProfile(id: "u", asr: "r-asr", vad: "x-vad", embedding: "x-emb", builtIn: false), "x-vad"),
            (testProfile(id: "u", asr: "r-asr", diarization: "x-diar", embedding: "x-emb", builtIn: false), "x-diar"),
            (testProfile(id: "u", asr: "r-asr", embedding: "x-emb", builtIn: false), "x-emb")
        ]
        for (profile, unknown) in cases {
            await expectCatalogError(.unknownModel(id: unknown, version: "")) { try await manager.saveProfile(profile) }
        }
        let ids = await manager.profiles().map(\.id)
        XCTAssertFalse(ids.contains("u"), "профиль не сохранён")
        let stored = try await harness.settings.value(forKey: ModelCatalogManager.userProfilesKey)
        XCTAssertNil(stored, "ничего не записано")

        try await manager.saveProfile(testProfile(id: "u", asr: "r-asr", vad: "r-orphan", builtIn: false))
        let saved = await manager.profiles().map(\.id)
        XCTAssertEqual(saved, ["u"], "вектор: модель инв. 33 (только на диске) — известна")
    }

    // MARK: - Инв. 34, пользовательский профиль

    func test_inv34_userProfileOnVanishedModelMissingModelsAndResolveThrowUnknownModelOtherRolesNil() async throws {
        let asr = model("g-asr", "1.0.0", seed: 8)
        let harness = ModelHarness(models: [asr])
        try harness.seedUserProfiles([
            testProfile(id: "gone-asr", asr: "gone", builtIn: false),
            testProfile(id: "gone-vad", asr: "g-asr", vad: "gone", builtIn: false)
        ])
        let manager = try harness.makeManager()
        try await manager.download(id: "g-asr", version: "1.0.0")

        await expectCatalogError(.unknownModel(id: "gone", version: "")) {
            _ = try await manager.missingModels(profileId: "gone-asr")
        }
        await expectCatalogError(.unknownModel(id: "gone", version: "")) {
            _ = try await manager.resolve(profileId: "gone-asr")
        }
        await expectCatalogError(.unknownModel(id: "gone", version: "")) {
            _ = try await manager.missingModels(profileId: "gone-vad")
        }
        let resolved = try await manager.resolve(profileId: "gone-vad")
        XCTAssertNil(resolved.vad, "прочие роли — nil (инв. 9)")
        XCTAssertEqual(resolved.asr.modelId, "g-asr")
    }

    // MARK: - Инв. 35

    func test_inv35_newestReadyBySemverPreReleaseOlderNumericComponents() async throws {
        let versions = ["2.9.0", "2.10.0", "3.0.0-beta"]
        let models = versions.enumerated().map { model("s-asr", $1, seed: UInt8(20 + $0)) }
        let harness = ModelHarness(models: models, profiles: [testProfile(id: "p", asr: "s-asr")])
        let manager = try harness.makeManager()
        for version in versions {
            try await manager.download(id: "s-asr", version: version)
        }
        let first = try await manager.resolve(profileId: "p")
        XCTAssertEqual(first.asr.version, "3.0.0-beta", "3.0.0-beta новее 2.10.0")

        try await manager.delete(id: "s-asr", version: "2.9.0")
        await expectCatalogError(.modelInUseByProfile(modelId: "s-asr", profileIds: ["p"])) {
            try await manager.delete(id: "s-asr", version: "3.0.0-beta")
        }
        let release = model("s-asr", "3.0.0", seed: 30)
        harness.models.append(release)
        harness.transport.setContent(release.contents["m.bin"] ?? Data(), at: release.url("m.bin"))
        harness.transport.setContent(try harness.catalogBytes(), at: ModelHarness.catalogURL)
        try await manager.refreshCatalog()
        let notYet = try await manager.resolve(profileId: "p")
        XCTAssertEqual(notYet.asr.version, "3.0.0-beta", "3.0.0 не скачана — выбирается готовая")
        try await manager.download(id: "s-asr", version: "3.0.0")
        let second = try await manager.resolve(profileId: "p")
        XCTAssertEqual(second.asr.version, "3.0.0", "релиз новее предрелиза той же тройки")
        try await manager.delete(id: "s-asr", version: "3.0.0-beta")
    }

    func test_inv35_diskOnlyModelParticipatesWhenCatalogHasOnlyUndownloadedNewer() async throws {
        let old = model("d-asr", "1.0.0", seed: 40)
        let newer = model("d-asr", "2.0.0", seed: 41)
        let harness = ModelHarness(models: [old], profiles: [testProfile(id: "p", asr: "d-asr")])
        let manager = try harness.makeManager()
        try await manager.download(id: "d-asr", version: "1.0.0")
        harness.models = [newer]
        harness.transport.setContent(try harness.catalogBytes(), at: ModelHarness.catalogURL)
        try await manager.refreshCatalog()

        let resolved = try await manager.resolve(profileId: "p")
        XCTAssertEqual(resolved.asr.version, "1.0.0", "модель инв. 33 на диске — кандидат")
        XCTAssertEqual(resolved.asr.directoryURL.standardizedFileURL, harness.directory(old).standardizedFileURL)
        let missing = try await manager.missingModels(profileId: "p")
        XCTAssertEqual(missing, [], "профиль готов")
        await expectCatalogError(.modelInUseByProfile(modelId: "d-asr", profileIds: ["p"])) {
            try await manager.delete(id: "d-asr", version: "1.0.0")
        }
    }
}
