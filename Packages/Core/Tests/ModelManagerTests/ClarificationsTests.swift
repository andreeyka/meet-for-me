//  К67, К68, К73 перечня MEE-429 (вторая поправка `2cb42043`; уточнения C-014 v7 от 29.09,
//  MEE-453 `a5bc1d63`): `delete` при нечитаемой строке профилей, повтор `id` в строке, порядок
//  отказов `saveProfile`. К69–К72 — в `ClarificationsTests+Versions.swift`.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class ClarificationsTests: XCTestCase {

    let key = "modelCatalog.userProfiles"

    func model(_ id: String, _ version: String = "1.0.0", role: ModelRole = .asr, seed: UInt8) -> TestModel {
        TestModel.make(id: id, version: version, role: role, files: [("m.bin", TestModel.bytes(24, seed: seed))])
    }

    func setValueCalls(_ harness: ModelHarness) -> Int {
        harness.settings.callLog.count(port: InMemorySettingsRepository.portName, method: "setValue(_:forKey:)")
    }

    // MARK: - К67

    func test_k67_deleteWithUnreadableProfilesRowThrowsUnreadableLeavesFilesReadableRowGivesInUse() async throws {
        let held = testProfile(id: "up", asr: "m", builtIn: false)
        let valid = try DomainJSON.encode([held])
        let runs: [(name: String, bytes: Data)] = [
            ("(i) отказ порта", valid),
            ("(ii) не разбирается", Data("{".utf8)),
            ("(iii) isBuiltIn == true", try DomainJSON.encode([held, testProfile(id: "zz", asr: "m")])),
            ("различающий: читаема", valid)
        ]
        for (index, run) in runs.enumerated() {
            let target = model("m", seed: 30)
            let harness = ModelHarness(models: [target])
            let manager = try harness.makeManager()
            try await manager.download(id: "m", version: "1.0.0")
            harness.settings.seed([key: run.bytes])
            if index == 0 {
                harness.settings.fail(with: .io(message: "диск"), on: .value)
            }
            let recorder = EventRecorder(manager.events())
            if index == 3 {
                await expectCatalogError(.modelInUseByProfile(modelId: "m", profileIds: ["up"])) {
                    try await manager.delete(id: "m", version: "1.0.0")
                }
            } else {
                await expectUserProfilesUnreadable { try await manager.delete(id: "m", version: "1.0.0") }
            }
            await recorder.settle()
            XCTAssertTrue(harness.exists(harness.directory(target).appendingPathComponent("m.bin")), run.name)
            let state = await manager.state(id: "m", version: "1.0.0")
            XCTAssertEqual(state, .downloaded, run.name)
            XCTAssertTrue(recorder.states(of: "m").isEmpty, "\(run.name): stateChanged не опубликован")
            XCTAssertEqual(setValueCalls(harness), 0, run.name)
        }
    }

    // MARK: - К68

    func test_k68_duplicateIdInRowIsUnreadableForFiveMethodsNothingWrittenProfilesBuiltInOnly() async throws {
        let asr = model("a", seed: 31)
        let harness = ModelHarness(models: [asr], profiles: [testProfile(id: "builtin", asr: "a")])
        let first = testProfile(id: "p1", asr: "a", builtIn: false)
        let second = TranscriptionProfile(
            id: "p1", displayName: "другой", language: "en", asrModelId: "a", vadModelId: nil,
            diarizationModelId: nil, embeddingModelId: nil,
            diarization: DiarizationParameters(expectedSpeakers: 2, clusteringThreshold: 0.5, minSegmentMs: 300),
            isBuiltIn: false)
        let bytes = try DomainJSON.encode([first, second])
        let manager = try harness.makeManager()
        try await manager.download(id: "a", version: "1.0.0")
        harness.settings.seed([key: bytes])

        await expectUserProfilesUnreadable {
            try await manager.saveProfile(testProfile(id: "p2", asr: "a", builtIn: false))
        }
        await expectUserProfilesUnreadable { try await manager.deleteProfile(id: "p1") }
        await expectUserProfilesUnreadable { _ = try await manager.resolve(profileId: "p1") }
        await expectUserProfilesUnreadable { _ = try await manager.missingModels(profileId: "p1") }
        await expectUserProfilesUnreadable { try await manager.delete(id: "a", version: "1.0.0") }
        let profiles = await manager.profiles()
        XCTAssertEqual(profiles.map(\.id), ["builtin"], "ни одна из двух записей p1 не выбрана")
        XCTAssertEqual(setValueCalls(harness), 0)
        let now = try await harness.settings.value(forKey: key)
        XCTAssertEqual(now, bytes, "байты строки не тронуты")
    }

    // MARK: - К73

    func test_k73_saveProfileRefusalOrderBuiltInThenUnknownModelThenUnreadableThenStorageError() async throws {
        struct Run {
            let name: String
            let profile: TranscriptionProfile
            let unreadable: Bool
            let expected: String
        }
        let runs = [
            Run(name: "(i)", profile: testProfile(id: "b", asr: "no-such"), unreadable: true,
                expected: "\(ModelCatalogError.builtInProfileImmutable(id: "b"))"),
            Run(name: "(ii)", profile: testProfile(id: "u", asr: "a", vad: "no-vad", builtIn: false), unreadable: true,
                expected: "\(ModelCatalogError.unknownModel(id: "no-vad", version: ""))"),
            Run(name: "(iii)", profile: testProfile(id: "u", asr: "a", builtIn: false), unreadable: true,
                expected: "userProfilesUnreadable"),
            Run(name: "(iv)", profile: testProfile(id: "u", asr: "a", builtIn: false), unreadable: false,
                expected: "\(StorageError.io(message: "запись"))")
        ]
        for run in runs {
            let harness = ModelHarness(models: [model("a", seed: 32)])
            if run.unreadable {
                harness.settings.seed([key: Data("{".utf8)])
            }
            harness.settings.fail(with: .io(message: "запись"), on: .setValue)
            let manager = try harness.makeManager()
            do {
                try await manager.saveProfile(run.profile)
                XCTFail("\(run.name): ожидался отказ")
            } catch {
                XCTAssertTrue("\(error)".hasPrefix(run.expected), "\(run.name): \(error)")
            }
            let ids = await manager.profiles().map(\.id)
            XCTAssertFalse(ids.contains(run.profile.id), "\(run.name): профиль не сохранён")
            XCTAssertEqual(setValueCalls(harness), run.unreadable ? 0 : 1, "\(run.name): setValue")
        }
    }
}
