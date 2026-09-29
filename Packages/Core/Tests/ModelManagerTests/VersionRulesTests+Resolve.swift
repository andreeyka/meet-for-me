//  К59–К60 перечня MEE-429 (поправка `d999d708`, C-014 v7; MEE-459): пользовательский профиль на
//  исчезнувшую модель (инв. 34, вторая половина) и выбор версии для профиля (инв. 35).

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

extension VersionRulesTests {

    // MARK: - К59

    func test_k59_userProfileOnVanishedModelUnknownModelOtherRolesNilDiskOnlyModelStillServes() async throws {
        for diskCopy in [false, true] {
            let run = diskCopy ? "В (x на диске, инв. 33)" : "А/Б"
            let asr = model("a", "1.0.0", seed: 8)
            let vanishing = model("x", "1.0.0", seed: 9)
            let diar = model("d", "1.0.0", role: .diarization, seed: 10)
            let harness = ModelHarness(models: [asr, vanishing, diar])
            let manager = try harness.makeManager()
            try await manager.saveProfile(testProfile(id: "up", asr: "x", builtIn: false))
            try await manager.saveProfile(testProfile(id: "ud", asr: "a", diarization: "d", builtIn: false))
            try await manager.download(id: "a", version: "1.0.0")
            if diskCopy {
                try await manager.download(id: "x", version: "1.0.0")
            }
            harness.models = [asr]
            harness.transport.setContent(try harness.catalogBytes(), at: ModelHarness.catalogURL)
            try await manager.refreshCatalog()       // пользовательский профиль инв. 34 не проверяет

            if diskCopy {
                let resolved = try await manager.resolve(profileId: "up")
                XCTAssertEqual(resolved.asr.modelId, "x", run)
                let missing = try await manager.missingModels(profileId: "up")
                XCTAssertEqual(missing, [], run)
            } else {
                await expectCatalogError(.unknownModel(id: "x", version: "")) {
                    _ = try await manager.missingModels(profileId: "up")
                }
                await expectCatalogError(.unknownModel(id: "x", version: "")) {
                    _ = try await manager.resolve(profileId: "up")
                }
                await expectCatalogError(.unknownModel(id: "d", version: "")) {
                    _ = try await manager.missingModels(profileId: "ud")
                }
                let resolved = try await manager.resolve(profileId: "ud")
                XCTAssertNil(resolved.diarization, "Б: прочие роли — nil (инв. 9)")
                XCTAssertEqual(resolved.asr.modelId, "a")
            }
        }
    }

    // MARK: - К60

    /// Стенд инв. 35: профиль «p» с `asrModelId == "m"`; `download` — версии, скачанные до старта
    /// проверки; `catalogAfter` — версии каталога после `refreshCatalog` (модели инв. 33).
    private func versionStand(_ versions: [String], download: [String],
                              catalogAfter: [String]? = nil) async throws -> (ModelHarness, ModelCatalogManager) {
        let models = versions.enumerated().map { model("m", $1, seed: UInt8(20 + $0)) }
        let harness = ModelHarness(models: models, profiles: [testProfile(id: "p", asr: "m")])
        let manager = try harness.makeManager()
        for version in download {
            try await manager.download(id: "m", version: version)
        }
        if let catalogAfter {
            harness.models = models.filter { catalogAfter.contains($0.descriptor.version) }
            harness.transport.setContent(try harness.catalogBytes(), at: ModelHarness.catalogURL)
            try await manager.refreshCatalog()
        }
        return (harness, manager)
    }

    func test_k60_newestReadyVersionBySemverWithDiskOnlyCandidates() async throws {
        struct Run {
            let name: String
            let versions: [String]
            let downloaded: [String]
            var catalogAfter: [String]?
            let expected: String
        }
        let runs = [
            Run(name: "(i)", versions: ["1.9.0", "1.10.0"], downloaded: ["1.9.0", "1.10.0"], expected: "1.10.0"),
            Run(name: "(ii)", versions: ["3.0.0-beta", "3.0.0"], downloaded: ["3.0.0-beta", "3.0.0"],
                expected: "3.0.0"),
            Run(name: "(iii)", versions: ["3.0.0-beta", "2.0.0", "3.0.0"], downloaded: ["3.0.0-beta", "2.0.0"],
                expected: "3.0.0-beta"),
            Run(name: "(iv)", versions: ["2.0.0", "1.0.0"], downloaded: ["1.0.0"], expected: "1.0.0"),
            Run(name: "(v)", versions: ["2.0.0", "1.0.0"], downloaded: ["1.0.0"], catalogAfter: ["2.0.0"],
                expected: "1.0.0")
        ]
        var stands: [ModelHarness] = []           // временный корень живёт, пока жив стенд
        for run in runs {
            let (harness, manager) = try await versionStand(run.versions, download: run.downloaded,
                                                      catalogAfter: run.catalogAfter)
            if run.catalogAfter != nil {
                let listed = await manager.models().map(\.version)
                XCTAssertEqual(listed, ["2.0.0"], "\(run.name): вектор — 1.0.0 только на диске")
            }
            let resolved = try await manager.resolve(profileId: "p")
            XCTAssertEqual(resolved.asr.version, run.expected, run.name)
            stands.append(harness)
        }

        // (vi): 1.0.0 в `loaded`, 0.9.0 в `downloaded`.
        let (harness, manager) = try await versionStand(["1.0.0", "0.9.0"], download: ["1.0.0", "0.9.0"])
        let loaded = ModelBundle(modelId: "m", version: "1.0.0", role: .asr, runtime: .onnx,
                                 directoryURL: harness.directory(harness.models[0]))
        let token = try await manager.beginUse([loaded])
        let loadedState = await manager.state(id: "m", version: "1.0.0")
        XCTAssertEqual(loadedState, .loaded, "(vi): вектор")
        let resolved = try await manager.resolve(profileId: "p")
        XCTAssertEqual(resolved.asr.version, "1.0.0", "(vi)")
        await manager.endUse(token)

        // (vii): готовой нет.
        let (idleHarness, idle) = try await versionStand(["1.0.0", "2.0.0"], download: [])
        await expectCatalogError(.notDownloaded(modelId: "m", version: "2.0.0")) {
            _ = try await idle.resolve(profileId: "p")
        }
        let missing = try await idle.missingModels(profileId: "p")
        XCTAssertEqual(missing.map(\.version), ["2.0.0"], "(vii): новейшая версия каталога, не 1.0.0")
        XCTAssertEqual(stands.count + [harness, idleHarness].count, 7, "семь прогонов")
    }
}
