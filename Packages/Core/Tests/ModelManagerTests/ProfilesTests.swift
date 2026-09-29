//  К41–К43, К51 перечня MEE-429 (группа К; К42 и К43 — в редакции поправки `d999d708`,
//  C-014 v7): встроенные профили неизменяемы, `saveProfile` с неизвестной моделью, запрет
//  удаления версии, которую профиль разрешает, переопределение встроенного пользовательским.

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
            testProfile(id: "p1", asr: "p-asr", vad: "p-vad")
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

    /// К42 (поправка `d999d708`, инв. 13 v7): А — модели нет нигде; Б — есть только не скачанная;
    /// В — есть только на диске по инв. 33.
    func test_k42_saveProfileWithUnknownAsrModelIdThrows() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let profile = testProfile(id: "mine", asr: "no-such-model", builtIn: false)
        await expect(.unknownModel(id: "no-such-model", version: "")) { try await manager.saveProfile(profile) }
        let ids = await manager.profiles().map(\.id)
        XCTAssertFalse(ids.contains("mine"), "профиль не сохранён")
        let row = try await harness.settings.value(forKey: ModelCatalogManager.userProfilesKey)
        XCTAssertNil(row, "и в modelCatalog.userProfiles его нет")

        let state = await manager.state(id: "p-free", version: "1.0.0")
        XCTAssertEqual(state, .available, "вектор Б: p-free не скачана")
        try await manager.saveProfile(testProfile(id: "mine", asr: "p-free", builtIn: false))
        let saved = await manager.profiles().map(\.id)
        XCTAssertTrue(saved.contains("mine"), "Б: инв. 13 спрашивает «есть ли», а не «готова ли»")

        // В: запись p-emb исчезает из каталога, файлы с `.manifest.json` остаются (инв. 33).
        try await manager.download(id: "p-emb", version: "1.0.0")
        harness.models.removeAll { $0.descriptor.id == "p-emb" }
        harness.transport.setContent(try harness.catalogBytes(), at: ModelHarness.catalogURL)
        try await manager.refreshCatalog()
        let inCatalog = await manager.models().map(\.id)
        XCTAssertFalse(inCatalog.contains("p-emb"), "вектор В: записи в каталоге нет")
        try await manager.saveProfile(testProfile(id: "disk", asr: "p-emb", builtIn: false))
        let withDisk = await manager.profiles().map(\.id)
        XCTAssertTrue(withDisk.contains("disk"), "В: модель инв. 33 известна")
    }

    /// К43 (поправка `d999d708`, инв. 11 v7): каждая роль и каждое происхождение профиля —
    /// отдельный прогон; два профиля «p2» и «p1» разрешают `m@1.0.0` — список по возрастанию `id`.
    func test_k43_deleteModelInUseByAnyRoleOrUserProfileThrowsListsProfilesLeavesFiles() async throws {
        let roles: [ModelRole] = [.asr, .vad, .diarization, .embedding]
        for role in roles {
            for builtIn in [true, false] {
                let run = "\(role.rawValue), \(builtIn ? "встроенный" : "пользовательский")"
                let target = TestModel.make(id: "m", role: role, files: [("m.bin", TestModel.bytes(16, seed: 70))])
                let base = TestModel.make(id: "base", files: [("b.bin", TestModel.bytes(16, seed: 71))])
                let referencing = ["p2", "p1"].map { id in
                    role == .asr
                        ? testProfile(id: id, asr: "m", builtIn: builtIn)
                        : testProfile(id: id, asr: "base", vad: role == .vad ? "m" : nil,
                                      diarization: role == .diarization ? "m" : nil,
                                      embedding: role == .embedding ? "m" : nil, builtIn: builtIn)
                }
                let harness = ModelHarness(models: [target, base], profiles: builtIn ? referencing : [])
                if !builtIn {
                    try harness.seedUserProfiles(referencing)
                }
                let manager = try harness.makeManager()
                try await manager.download(id: "m", version: "1.0.0")
                if role != .asr {
                    try await manager.download(id: "base", version: "1.0.0")   // профиль готов целиком
                }
                await expect(.modelInUseByProfile(modelId: "m", profileIds: ["p1", "p2"])) {
                    try await manager.delete(id: "m", version: "1.0.0")
                }
                XCTAssertTrue(harness.exists(harness.directory(target).appendingPathComponent("m.bin")), run)
                let state = await manager.state(id: "m", version: "1.0.0")
                XCTAssertEqual(state, .downloaded, run)
            }
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
