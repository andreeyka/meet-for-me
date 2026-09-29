//  К52–К54 перечня MEE-429 (поправка `d999d708`, C-014 v7; MEE-459): инв. 11 защищает только
//  версию, которую разрешает профиль (инв. 35); `loaded` без профиля — `modelInUse`, порядок
//  «сначала профили»; инв. 13 по всем четырём ролям. К59–К60 — в `VersionRulesTests+Resolve`.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class VersionRulesTests: XCTestCase {

    func model(_ id: String, _ version: String, role: ModelRole = .asr, seed: UInt8) -> TestModel {
        TestModel.make(id: id, version: version, role: role, files: [("m.bin", TestModel.bytes(24, seed: seed))])
    }

    // MARK: - К52

    func test_k52_olderAndUnfinishedVersionsDeletableResolvedVersionStaysProtected() async throws {
        let old = model("m", "1.0.0", seed: 1)
        let current = model("m", "2.0.0", seed: 2)
        let unfinished = model("m", "3.0.0", seed: 3)
        let harness = ModelHarness(models: [old, current, unfinished], profiles: [testProfile(id: "p", asr: "m")])
        harness.transport.chunkSize = 8
        harness.transport.script(unfinished.url("m.bin"), [.dropAfter(bytes: 8)])
        let manager = try harness.makeManager()
        try await manager.download(id: "m", version: "1.0.0")
        try await manager.download(id: "m", version: "2.0.0")
        _ = try? await manager.download(id: "m", version: "3.0.0")
        let unfinishedState = await manager.state(id: "m", version: "3.0.0")
        XCTAssertEqual(unfinishedState, .paused(bytesOnDisk: 8), "вектор: 3.0.0 недокачана")

        try await manager.delete(id: "m", version: "1.0.0")
        try await manager.delete(id: "m", version: "3.0.0")
        for item in [old, unfinished] {
            let version = item.descriptor.version
            XCTAssertFalse(harness.exists(harness.directory(item)), "\(version): каталог удалён целиком")
            let state = await manager.state(id: "m", version: version)
            XCTAssertEqual(state, .available, version)
        }
        XCTAssertTrue(harness.exists(harness.directory(current).appendingPathComponent("m.bin")))
        await expectCatalogError(.modelInUseByProfile(modelId: "m", profileIds: ["p"])) {
            try await manager.delete(id: "m", version: "2.0.0")
        }
    }

    // MARK: - К53

    func test_k53_loadedWithoutResolvingProfileThrowsModelInUseProfilesCheckedFirst() async throws {
        let target = model("m", "1.0.0", seed: 4)
        let base = model("base", "1.0.0", seed: 5)
        let harness = ModelHarness(models: [target, base], profiles: [testProfile(id: "b", asr: "base")])
        let manager = try harness.makeManager()
        try await manager.download(id: "m", version: "1.0.0")
        try await manager.saveProfile(testProfile(id: "p", asr: "m", builtIn: false))

        // А: профиль разрешал, задача взяла расписку, профиль удалён — ни один профиль не разрешает.
        let resolved = try await manager.resolve(profileId: "p")
        let token = try await manager.beginUse([resolved.asr])
        let recorder = EventRecorder(manager.events())
        try await manager.deleteProfile(id: "p")
        await expectCatalogError(.modelInUse(modelId: "m", version: "1.0.0")) {
            try await manager.delete(id: "m", version: "1.0.0")
        }
        XCTAssertTrue(harness.exists(harness.directory(target).appendingPathComponent("m.bin")), "файлы на месте")
        let whileLoaded = await manager.state(id: "m", version: "1.0.0")
        XCTAssertEqual(whileLoaded, .loaded)
        await recorder.settle()
        XCTAssertFalse(recorder.states(of: "m").contains(.available), "loaded → available не публикуется")
        await manager.endUse(token)
        try await manager.delete(id: "m", version: "1.0.0")
        let after = await manager.state(id: "m", version: "1.0.0")
        XCTAssertEqual(after, .available, "после endUse тот же delete успешен")

        // Б: `loaded`, и профиль её разрешает — `modelInUseByProfile`, не `modelInUse`.
        try await manager.download(id: "base", version: "1.0.0")
        let busy = try await manager.beginUse([try await manager.resolve(profileId: "b").asr])
        await expectCatalogError(.modelInUseByProfile(modelId: "base", profileIds: ["b"])) {
            try await manager.delete(id: "base", version: "1.0.0")
        }
        await manager.endUse(busy)
    }

    // MARK: - К54

    func test_k54_saveProfileChecksVadDiarizationEmbeddingFirstMissingInRoleOrder() async throws {
        let harness = ModelHarness(models: [model("r-asr", "1.0.0", seed: 6)])
        let manager = try harness.makeManager()
        let missingVad = testProfile(id: "u", asr: "r-asr", vad: "v?", builtIn: false)
        let runs: [(expected: String, profile: TranscriptionProfile)] = [
            ("v?", missingVad),                                                                   // (i)
            ("d?", testProfile(id: "u", asr: "r-asr", diarization: "d?", builtIn: false)),        // (ii)
            ("e?", testProfile(id: "u", asr: "r-asr", embedding: "e?", builtIn: false)),          // (iii)
            ("v?", testProfile(id: "u", asr: "r-asr", vad: "v?", embedding: "e?", builtIn: false)) // (iv)
        ]
        for run in runs {
            await expectCatalogError(.unknownModel(id: run.expected, version: "")) {
                try await manager.saveProfile(run.profile)
            }
            let ids = await manager.profiles().map(\.id)
            XCTAssertFalse(ids.contains("u"), "\(run.expected): профиль не сохранён")
        }
        let row = try await harness.settings.value(forKey: ModelCatalogManager.userProfilesKey)
        XCTAssertNil(row, "ничего не записано")
        try await manager.saveProfile(testProfile(id: "u", asr: "r-asr", builtIn: false))
        let saved = await manager.profiles().map(\.id)
        XCTAssertEqual(saved, ["u"], "nil в необязательных ролях — не отказ")
    }
}
