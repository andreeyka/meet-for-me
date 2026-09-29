//  К37–К40 перечня MEE-429 (план MEE-436, группа И): `resolve(profileId:)` и
//  `missingModels(profileId:)` (инв. 8, 9, 10, 19).

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class ResolveTests: XCTestCase {

    /// Четыре модели по ролям; профиль «full» ссылается на все четыре, «bare» — только на asr.
    private func makeHarness() -> ModelHarness {
        let roles: [(String, ModelRole)] = [("r-asr", .asr), ("r-vad", .vad), ("r-diar", .diarization),
                                            ("r-emb", .embedding)]
        let models = roles.enumerated().map { index, pair in
            TestModel.make(id: pair.0, role: pair.1,
                           files: [("\(pair.0).onnx", TestModel.bytes(20, seed: UInt8(40 + index))),
                                   ("\(pair.0).txt", TestModel.bytes(5, seed: UInt8(50 + index)))])
        }
        let profiles = [
            testProfile(id: "full", asr: "r-asr", vad: "r-vad", diarization: "r-diar", embedding: "r-emb"),
            testProfile(id: "bare", asr: "r-asr")
        ]
        return ModelHarness(models: models, profiles: profiles)
    }

    func test_k37_resolveThrowsNotDownloadedForAsrElsePassesForDownloadedOrLoaded() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        do {
            _ = try await manager.resolve(profileId: "bare")
            XCTFail("asr в available — ожидался notDownloaded")
        } catch let error as ModelCatalogError {
            XCTAssertEqual(error, .notDownloaded(modelId: "r-asr", version: "1.0.0"))
        }
        try await manager.download(id: "r-asr", version: "1.0.0")
        let resolved = try await manager.resolve(profileId: "bare")
        XCTAssertEqual(resolved.asr.modelId, "r-asr", "asr в downloaded — не бросает")
        let token = try await manager.beginUse([resolved.asr])
        let loaded = await manager.state(id: "r-asr", version: "1.0.0")
        XCTAssertEqual(loaded, .loaded, "вектор: asr в loaded")
        let again = try await manager.resolve(profileId: "bare")
        XCTAssertEqual(again.asr, resolved.asr, "asr в loaded — не бросает")
        await manager.endUse(token)
    }

    func test_k38_resolveLeavesAllThreeOptionalRolesNilWithoutThrowingWhenMissing() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        try await manager.download(id: "r-asr", version: "1.0.0")
        let full = try await manager.resolve(profileId: "full")
        XCTAssertNil(full.vad, "vadModelId задан, модель не скачана — nil")
        XCTAssertNil(full.diarization)
        XCTAssertNil(full.embedding)
        let bare = try await manager.resolve(profileId: "bare")
        XCTAssertNil(bare.vad, "vadModelId == nil — nil")
        XCTAssertNil(bare.diarization)
        XCTAssertNil(bare.embedding)

        for id in ["r-vad", "r-diar", "r-emb"] {
            try await manager.download(id: id, version: "1.0.0")
        }
        let complete = try await manager.resolve(profileId: "full")
        XCTAssertEqual(complete.vad?.modelId, "r-vad", "вектор непустоты: скачанная роль заполняется")
        XCTAssertEqual(complete.diarization?.role, .diarization)
        XCTAssertEqual(complete.embedding?.role, .embedding)
    }

    func test_k39_resolvedBundleDirectoryExistsWithAllFilesAtIssueTime() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        for model in harness.models {
            try await manager.download(id: model.descriptor.id, version: "1.0.0")
        }
        let resolved = try await manager.resolve(profileId: "full")
        let bundles = [resolved.asr] + [resolved.vad, resolved.diarization, resolved.embedding].compactMap { $0 }
        XCTAssertEqual(bundles.count, 4)
        for bundle in bundles {
            let descriptor = try XCTUnwrap(harness.models.first { $0.descriptor.id == bundle.modelId }?.descriptor)
            XCTAssertTrue(harness.exists(bundle.directoryURL), "\(bundle.modelId): каталог существует")
            for file in descriptor.files {
                XCTAssertTrue(harness.exists(bundle.directoryURL.appendingPathComponent(file.name)),
                              "\(bundle.modelId): \(file.name) на месте")
            }
        }
    }

    func test_k40_missingModelsListsExactlyUnreadyRoles() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        for id in ["r-asr", "r-vad", "r-emb"] {
            try await manager.download(id: id, version: "1.0.0")
        }
        let missing = try await manager.missingModels(profileId: "full")
        let diarization = harness.models.first { $0.descriptor.id == "r-diar" }?.descriptor
        XCTAssertEqual(missing, [diarization].compactMap { $0 }, "ровно недостающая модель diarization")
        try await manager.download(id: "r-diar", version: "1.0.0")
        let none = try await manager.missingModels(profileId: "full")
        XCTAssertEqual(none, [], "профиль готов целиком — пустой массив")
    }
}
