//  К41–К43, К51 перечня MEE-429 (план MEE-436, группа К): встроенные профили неизменяемы,
//  `saveProfile` с неизвестной моделью, запрет удаления модели, на которую ссылается профиль,
//  переопределение встроенного профиля пользовательским по `id`.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class ProfilesTests: XCTestCase {

    private func makeHarness() -> ModelHarness {
        let ids: [(String, ModelRole)] = [("p-asr", .asr), ("p-vad", .vad), ("p-diar", .diarization),
                                          ("p-emb", .embedding), ("p-free", .asr)]
        let models = ids.enumerated().map { index, pair in
            TestModel.make(id: pair.0, role: pair.1,
                           files: [("\(pair.0).bin", TestModel.bytes(16, seed: UInt8(60 + index)))])
        }
        return ModelHarness(models: models, profiles: [
            testProfile(id: "p1", asr: "p-asr", vad: "p-vad"),
        ])
    }

    private func expect(_ expected: ModelCatalogError, _ body: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("ожидался \(expected)", file: file, line: line)
        } catch let error as ModelCatalogError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("ожидался \(expected), получено \(error)", file: file, line: line)
        }
    }

    func test_k41_builtInProfileSaveAndDeleteBothThrowImmutable() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let before = await manager.profiles()
        let edited = testProfile(id: "p1", asr: "p-free", builtIn: true)
        await expect(.builtInProfileImmutable(id: "p1")) { try await manager.saveProfile(edited) }
        await expect(.builtInProfileImmutable(id: "p1")) { try await manager.deleteProfile(id: "p1") }
        let after = await manager.profiles()
        XCTAssertEqual(after, before, "встроенный профиль не изменён и не удалён")
    }

    func test_k42_saveProfileWithUnknownAsrModelIdThrows() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let profile = testProfile(id: "mine", asr: "no-such-model", builtIn: false)
        await expect(.unknownModel(id: "no-such-model", version: "")) { try await manager.saveProfile(profile) }
        let ids = await manager.profiles().map(\.id)
        XCTAssertFalse(ids.contains("mine"), "профиль не сохранён")
        try await manager.saveProfile(testProfile(id: "mine", asr: "p-free", builtIn: false))
        let saved = await manager.profiles().map(\.id)
        XCTAssertTrue(saved.contains("mine"), "вектор непустоты: с известной моделью — сохраняется")
    }

    func test_k43_deleteModelInUseByAnyRoleOrUserProfileThrowsListsProfilesLeavesFiles() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        for model in harness.models {
            try await manager.download(id: model.descriptor.id, version: "1.0.0")
        }
        try await manager.saveProfile(testProfile(id: "u-diar", asr: "p-free", diarization: "p-diar", builtIn: false))
        try await manager.saveProfile(testProfile(id: "u-emb", asr: "p-free", embedding: "p-emb", builtIn: false))
        try await manager.saveProfile(testProfile(id: "u-vad", asr: "p-free", vad: "p-vad", builtIn: false))
        let cases: [(String, [String])] = [
            ("p-asr", ["p1"]),                 // asr встроенного профиля
            ("p-vad", ["p1", "u-vad"]),        // vad встроенного и пользовательского
            ("p-diar", ["u-diar"]),            // diarization пользовательского
            ("p-emb", ["u-emb"]),              // embedding пользовательского
            ("p-free", ["u-diar", "u-emb", "u-vad"]),
        ]
        for (modelId, profileIds) in cases {
            await expect(.modelInUseByProfile(modelId: modelId, profileIds: profileIds)) {
                try await manager.delete(id: modelId, version: "1.0.0")
            }
            let model = try XCTUnwrap(harness.models.first { $0.descriptor.id == modelId })
            XCTAssertTrue(harness.exists(harness.directory(model).appendingPathComponent("\(modelId).bin")),
                          "\(modelId): файлы не тронуты")
            let state = await manager.state(id: modelId, version: "1.0.0")
            XCTAssertEqual(state, .downloaded)
        }
    }

    func test_k51_userProfileOverridesBuiltInByIdExactlyOneEntry() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let override = testProfile(id: "p1", asr: "p-free", builtIn: false)
        try await manager.saveProfile(override)
        let profiles = await manager.profiles()
        let matching = profiles.filter { $0.id == "p1" }
        XCTAssertEqual(matching.count, 1, "ровно одна запись с id p1")
        XCTAssertEqual(matching.first, override, "пользовательская версия, isBuiltIn == false")
        try await manager.deleteProfile(id: "p1")
        let restored = await manager.profiles().filter { $0.id == "p1" }
        XCTAssertEqual(restored.map(\.isBuiltIn), [true], "после удаления пользовательской — снова встроенный")
    }
}
