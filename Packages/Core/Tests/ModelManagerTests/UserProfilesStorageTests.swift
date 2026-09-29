//  Инвариант 37 (C-014 v7, IR-141 п. 1; MEE-459): пользовательские профили — одна строка
//  `app_settings` под ключом `modelCatalog.userProfiles`, `DomainJSON` массива по `id`.
//  Порт — `InMemorySettingsRepository` (C-010, «Фейк для тестов»), общий для «перезапусков».

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

/// Ожидание `ModelCatalogError` — общая оснастка тестов издания v7.
func expectCatalogError(_ expected: ModelCatalogError, file: StaticString = #filePath, line: UInt = #line,
                        _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("ожидался \(expected)", file: file, line: line)
    } catch let error as ModelCatalogError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("ожидался \(expected), получено \(error)", file: file, line: line)
    }
}

/// Отказ `userProfilesUnreadable`, в сообщении которого назван ключ.
func expectUserProfilesUnreadable(file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("ожидался userProfilesUnreadable", file: file, line: line)
    } catch ModelCatalogError.userProfilesUnreadable(let message) {
        XCTAssertTrue(message.contains(ModelCatalogManager.userProfilesKey), message, file: file, line: line)
    } catch {
        XCTFail("ожидался userProfilesUnreadable, получено \(error)", file: file, line: line)
    }
}

final class UserProfilesStorageTests: XCTestCase {

    private let key = "modelCatalog.userProfiles"

    private func makeHarness() -> ModelHarness {
        let asr = TestModel.make(id: "us-asr", files: [("a.bin", TestModel.bytes(16, seed: 5))])
        let vad = TestModel.make(id: "us-vad", role: .vad, files: [("v.bin", TestModel.bytes(16, seed: 6))])
        return ModelHarness(models: [asr, vad], profiles: [testProfile(id: "builtin", asr: "us-asr")])
    }

    private func stored(_ harness: ModelHarness) async throws -> [TranscriptionProfile]? {
        guard let data = try await harness.settings.value(forKey: key) else { return nil }
        return try DomainJSON.decode([TranscriptionProfile].self, from: data)
    }

    private func setValueCalls(_ harness: ModelHarness) -> Int {
        harness.settings.callLog.count(port: InMemorySettingsRepository.portName, method: "setValue(_:forKey:)")
    }

    func test_inv37_keyIsDottedName() {
        XCTAssertEqual(ModelCatalogManager.userProfilesKey, key)
    }

    func test_inv37_writeThenReadRoundTripsSortedByIdAcrossRestart() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let zeta = testProfile(id: "zeta", asr: "us-asr", vad: "us-vad", builtIn: false)
        let alpha = testProfile(id: "alpha", asr: "us-asr", builtIn: false)
        try await manager.saveProfile(zeta)
        try await manager.saveProfile(alpha)

        let bytes = try await harness.settings.value(forKey: key)
        XCTAssertEqual(bytes, try DomainJSON.encode([alpha, zeta]), "DomainJSON массива, по возрастанию id")

        let restarted = try harness.makeManager()
        let ids = await restarted.profiles().map(\.id)
        XCTAssertEqual(ids, ["builtin", "alpha", "zeta"], "после перезапуска прочитано из app_settings")
        let reread = await restarted.profiles().first { $0.id == "zeta" }
        XCTAssertEqual(reread, zeta)

        try await restarted.deleteProfile(id: "alpha")
        let afterDelete = try await stored(harness)
        XCTAssertEqual(afterDelete, [zeta], "deleteProfile пишет массив целиком")
        try await restarted.deleteProfile(id: "zeta")
        let empty = try await stored(harness)
        XCTAssertEqual(empty, [], "профилей нет — значение []")
    }

    func test_inv37_noRowMeansNoUserProfilesAndSaveCreatesIt() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let ids = await manager.profiles().map(\.id)
        XCTAssertEqual(ids, ["builtin"], "строки нет — штатный первый запуск")
        let resolved = try? await manager.missingModels(profileId: "builtin")
        XCTAssertNotNil(resolved, "строки нет — не отказ")
        XCTAssertTrue(harness.settings.storedKeys.isEmpty, "чтение строку не создаёт")
        try await manager.saveProfile(testProfile(id: "mine", asr: "us-asr", builtIn: false))
        XCTAssertEqual(harness.settings.storedKeys, [key])
    }

    func test_inv37_unreadableBytesThrowOnFourMethodsWriteNothingProfilesGiveBuiltInOnly() async throws {
        let harness = makeHarness()
        let garbage = Data("{не json".utf8)
        harness.settings.seed([key: garbage])
        try await assertUnreadableState(harness, bytes: garbage)
    }

    func test_inv37_builtInEntryInStoredArrayIsUnreadable() async throws {
        let harness = makeHarness()
        try harness.seedUserProfiles([testProfile(id: "sneaky", asr: "us-asr", builtIn: true)])
        let bytes = try await harness.settings.value(forKey: key)
        try await assertUnreadableState(harness, bytes: try XCTUnwrap(bytes))
    }

    func test_inv37_portReadFailureIsUnreadableAndReadIsRetriedOnNextCall() async throws {
        let harness = makeHarness()
        let mine = testProfile(id: "mine", asr: "us-asr", builtIn: false)
        try harness.seedUserProfiles([mine])
        harness.settings.fail(with: .io(message: "диск"), on: .value)
        let manager = try harness.makeManager()
        await expectUserProfilesUnreadable { _ = try await manager.resolve(profileId: "mine") }
        let during = await manager.profiles().map(\.id)
        XCTAssertEqual(during, ["builtin"])

        harness.settings.clearFailure(on: .value)
        let after = await manager.profiles().map(\.id)
        XCTAssertEqual(after, ["builtin", "mine"], "пока чтение не удалось — читается заново")
    }

    func test_inv37_writeFailureLeavesMemoryAndEventsUnchanged() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let kept = testProfile(id: "kept", asr: "us-asr", builtIn: false)
        try await manager.saveProfile(kept)
        let before = await manager.profiles()
        let recorder = EventRecorder(manager.events())
        harness.settings.fail(with: .io(message: "нет места"), on: .setValue)

        do {
            try await manager.saveProfile(testProfile(id: "new", asr: "us-asr", builtIn: false))
            XCTFail("отказ записи обязан выйти наружу")
        } catch let error as StorageError {
            XCTAssertEqual(error, .io(message: "нет места"), "StorageError как есть")
        }
        do {
            try await manager.deleteProfile(id: "kept")
            XCTFail("отказ записи обязан выйти наружу")
        } catch let error as StorageError {
            XCTAssertEqual(error, .io(message: "нет места"))
        }
        await recorder.settle()
        let after = await manager.profiles()
        XCTAssertEqual(after, before, "ни память, ни profiles() не изменились")
        XCTAssertFalse(recorder.events.contains(.profilesChanged), "profilesChanged не публикуется")
        let storedNow = try await stored(harness)
        XCTAssertEqual(storedNow, [kept])
    }

    // MARK: - Оснастка

    /// Строка есть, а не читается: четыре метода бросают, ничего не пишется, `profiles()` — встроенные.
    private func assertUnreadableState(_ harness: ModelHarness, bytes: Data,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let manager = try harness.makeManager()
        let profiles = await manager.profiles().map(\.id)
        XCTAssertEqual(profiles, ["builtin"], "только встроенные", file: file, line: line)
        await expectUserProfilesUnreadable(file: file, line: line) {
            try await manager.saveProfile(testProfile(id: "mine", asr: "us-asr", builtIn: false))
        }
        await expectUserProfilesUnreadable(file: file, line: line) { try await manager.deleteProfile(id: "mine") }
        await expectUserProfilesUnreadable(file: file, line: line) {
            _ = try await manager.resolve(profileId: "builtin")   // и для id встроенного
        }
        await expectUserProfilesUnreadable(file: file, line: line) {
            _ = try await manager.missingModels(profileId: "builtin")
        }
        XCTAssertEqual(setValueCalls(harness), 0, "перезаписи нет", file: file, line: line)
        let now = try await harness.settings.value(forKey: key)
        XCTAssertEqual(now, bytes, "байты строки не тронуты", file: file, line: line)
    }
}
