//  К62–К66 перечня MEE-429 (поправка `d999d708`; C-014 v7 инв. 37, IR-141 п. 1; MEE-459):
//  пользовательские профили — одна строка `app_settings` под ключом `modelCatalog.userProfiles`,
//  `DomainJSON` массива по `id`. Порт — `InMemorySettingsRepository` (C-010, «Фейк для тестов»).

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

    private func setValueCalls(_ harness: ModelHarness) -> Int {
        harness.settings.callLog.count(port: InMemorySettingsRepository.portName, method: "setValue(_:forKey:)")
    }

    func test_keyIsDottedName() {
        XCTAssertEqual(ModelCatalogManager.userProfilesKey, key)
    }

    // MARK: - К62

    func test_k62_noRowThenWriteSortedByIdReadBackByNewInstanceEmptyArrayAfterDeletes() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let before = await manager.profiles().map(\.id)
        XCTAssertEqual(before, ["builtin"], "строки нет — только встроенные, без отказа")
        let p2 = testProfile(id: "p2", asr: "us-asr", vad: "us-vad", builtIn: false)
        let p1 = testProfile(id: "p1", asr: "us-asr", builtIn: false)
        try await manager.saveProfile(p2)
        try await manager.saveProfile(p1)
        let bytes = try await harness.settings.value(forKey: key)
        XCTAssertEqual(bytes, try DomainJSON.encode([p1, p2]), "по id, а не по времени сохранения")

        let restarted = try harness.makeManager()
        let reread = await restarted.profiles()
        XCTAssertEqual(reread.map(\.id), ["builtin", "p1", "p2"])
        XCTAssertEqual(reread.last, p2)

        try await restarted.deleteProfile(id: "p1")
        try await restarted.deleteProfile(id: "p2")
        let empty = try await harness.settings.value(forKey: key)
        XCTAssertEqual(empty, try DomainJSON.encode([TranscriptionProfile]()), "профилей нет — значение []")
    }

    // MARK: - К63

    func test_k63_writeFailureThrowsStorageErrorAsIsNoMemoryChangeNoEventSuccessEventAfterWrite() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        let old = testProfile(id: "old", asr: "us-asr", builtIn: false)
        try await manager.saveProfile(old)
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
            try await manager.deleteProfile(id: "old")
            XCTFail("отказ записи обязан выйти наружу")
        } catch let error as StorageError {
            XCTAssertEqual(error, .io(message: "нет места"))
        }
        await recorder.settle()
        let after = await manager.profiles()
        XCTAssertEqual(after, before, "ни память, ни profiles() не изменились")
        XCTAssertFalse(recorder.events.contains(.profilesChanged), "profilesChanged не публикуется")

        // Порядок: при успешной записи событие приходит, когда значение ключа уже новое.
        harness.settings.clearFailure(on: .setValue)
        let settings = harness.settings, key = self.key
        let atEvent = Probe<[Data?]>([])
        let stream = manager.events()
        let watcher = Task {
            for await event in stream where event == .profilesChanged {
                let value = try? await settings.value(forKey: key)
                atEvent.update { $0.append(value ?? nil) }
                return
            }
        }
        let fresh = testProfile(id: "fresh", asr: "us-asr", builtIn: false)
        try await manager.saveProfile(fresh)
        await watcher.value
        XCTAssertEqual(atEvent.value, [try DomainJSON.encode([fresh, old])], "к событию значение уже новое")
    }

    // MARK: - К64

    func test_k64_unreadableRowPortFailureBadBytesOrBuiltInEntryFourMethodsThrowNothingWritten() async throws {
        let mine = testProfile(id: "mine", asr: "us-asr", builtIn: false)
        // (i) отказ порта на чтении.
        let failing = makeHarness()
        try failing.seedUserProfiles([mine])
        failing.settings.fail(with: .io(message: "диск"), on: .value)
        try await assertUnreadableState(failing, bytes: try DomainJSON.encode([mine]), clearingFailure: true)
        // (ii) байты не разбираются.
        let garbage = makeHarness()
        garbage.settings.seed([key: Data("{".utf8)])
        try await assertUnreadableState(garbage, bytes: Data("{".utf8))
        // (iii) запись с `isBuiltIn == true` в массиве.
        let sneaky = makeHarness()
        let withBuiltIn = [mine, testProfile(id: "sneaky", asr: "us-asr", builtIn: true)]
        try sneaky.seedUserProfiles(withBuiltIn)
        try await assertUnreadableState(sneaky, bytes: try DomainJSON.encode(withBuiltIn))
    }

    // MARK: - К65

    func test_k65_readRetriedOnEveryCallUntilItSucceedsWithoutRecreatingManager() async throws {
        let harness = makeHarness()
        let p1 = testProfile(id: "p1", asr: "us-asr", builtIn: false)
        try harness.seedUserProfiles([p1])
        harness.settings.fail(with: .io(message: "диск"), on: .value)
        let manager = try harness.makeManager()
        try await manager.download(id: "us-asr", version: "1.0.0")
        await expectUserProfilesUnreadable { _ = try await manager.resolve(profileId: "p1") }

        harness.settings.clearFailure(on: .value)
        let resolved = try await manager.resolve(profileId: "p1")
        XCTAssertEqual(resolved.profileId, "p1", "следующий вызов прочитал строку заново")
        let ids = await manager.profiles().map(\.id)
        XCTAssertTrue(ids.contains("p1"))
    }

    // MARK: - К66

    func test_k66_profilesLiveOnlyInGivenSettingsRepositoryNotOnModelDisk() async throws {
        let harness = makeHarness()
        let manager = try harness.makeManager()
        try await manager.saveProfile(testProfile(id: "p2", asr: "us-asr", builtIn: false))
        try await manager.saveProfile(testProfile(id: "p1", asr: "us-asr", builtIn: false))

        let other = ModelCatalogManager(root: harness.root, catalogURL: ModelHarness.catalogURL,
                                        settings: InMemorySettingsRepository(), transport: harness.transport,
                                        environment: harness.machine, builtInCatalog: try harness.catalogBytes())
        let ids = await other.profiles().map(\.id)
        XCTAssertEqual(ids, ["builtin"], "тот же models/, другой пустой SettingsRepository — ни p1, ни p2")
    }

    // MARK: - Оснастка

    /// Строка есть, а не читается: четыре метода бросают (`resolve` — и для пользовательского, и для
    /// встроенного `id`), `setValue` не вызван, байты не тронуты, `profiles()` — только встроенные.
    private func assertUnreadableState(_ harness: ModelHarness, bytes: Data, clearingFailure: Bool = false,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let manager = try harness.makeManager()
        let profiles = await manager.profiles().map(\.id)
        XCTAssertEqual(profiles, ["builtin"], "только встроенные", file: file, line: line)
        await expectUserProfilesUnreadable(file: file, line: line) {
            try await manager.saveProfile(testProfile(id: "other", asr: "us-asr", builtIn: false))
        }
        await expectUserProfilesUnreadable(file: file, line: line) { try await manager.deleteProfile(id: "mine") }
        for id in ["mine", "builtin"] {
            await expectUserProfilesUnreadable(file: file, line: line) { _ = try await manager.resolve(profileId: id) }
        }
        await expectUserProfilesUnreadable(file: file, line: line) {
            _ = try await manager.missingModels(profileId: "builtin")
        }
        XCTAssertEqual(setValueCalls(harness), 0, "перезаписи нет", file: file, line: line)
        if clearingFailure {
            harness.settings.clearFailure(on: .value)
        }
        let now = try await harness.settings.value(forKey: key)
        XCTAssertEqual(now, bytes, "байты строки не тронуты", file: file, line: line)
    }
}
