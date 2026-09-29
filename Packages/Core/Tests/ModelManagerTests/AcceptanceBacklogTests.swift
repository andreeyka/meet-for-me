//  MEE-458 — бэклог приёмки #177: порядок semver с pre-release (п.1), `unknownModel` без
//  версии (п.2), свободное место на macOS (п.3), обратное давление транспорта (п.4).
//
//  П.4 проверяется на `BackpressureGate` — решение «остановить/возобновить» вынесено туда
//  целиком; что `URLSessionDataTask.suspend()/resume()` действительно останавливает поток
//  байт, без сети не проверить (§6: живой CDN в тестах не трогается).

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class AcceptanceBacklogTests: XCTestCase {

    // MARK: - П.1: semver, pre-release младше релиза

    func test_preReleaseIsOlderThanReleaseOfSameCore() {
        XCTAssertFalse(ModelVersionOrder.isNewer("3.0.0-beta", than: "3.0.0"))
        XCTAssertTrue(ModelVersionOrder.isNewer("3.0.0", than: "3.0.0-beta"))
        XCTAssertTrue(ModelVersionOrder.isNewer("3.0.0-beta", than: "2.9.9"), "ядро решает раньше pre-release")
    }

    /// Пример порядка из semver 2.0.0 §11 — каждая следующая строго новее предыдущей.
    func test_semverSpecPrecedenceChain() {
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                     "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.2.0", "1.10.0", "2.0.0"]
        for (older, newer) in zip(chain, chain.dropFirst()) {
            XCTAssertTrue(ModelVersionOrder.isNewer(newer, than: older), "\(newer) > \(older)")
            XCTAssertFalse(ModelVersionOrder.isNewer(older, than: newer), "\(older) < \(newer)")
        }
        XCTAssertFalse(ModelVersionOrder.isNewer("1.0.0+build.2", than: "1.0.0+build.1"), "метаданные сборки не в счёт")
        XCTAssertFalse(ModelVersionOrder.isNewer("1.0.0", than: "1.0.0"))
    }

    /// Через поведение: в каталоге `3.0.0` и `3.0.0-beta` одной модели, ни одна не скачана —
    /// `missingModels` называет новейшей релиз, а не pre-release.
    func test_missingModelsNamesReleaseNotPreReleaseAsNewest() async throws {
        let beta = TestModel.make(id: "sv-asr", version: "3.0.0-beta", files: [("m.onnx", TestModel.bytes(8, seed: 3))])
        let release = TestModel.make(id: "sv-asr", version: "3.0.0", files: [("m.onnx", TestModel.bytes(8, seed: 4))])
        let harness = ModelHarness(models: [release, beta], profiles: [testProfile(id: "p", asr: "sv-asr")])
        let manager = try harness.makeManager()

        let missing = try await manager.missingModels(profileId: "p")

        XCTAssertEqual(missing.map(\.version), ["3.0.0"])
    }

    // MARK: - П.2: unknownModel — версия не названа ни профилем, ни каталогом

    /// v7: встроенный профиль на несуществующую модель отвергает каталог целиком (инв. 34), поэтому
    /// «висящий» профиль здесь — пользовательский, уже лежащий в `app_settings` (инв. 37).
    func test_unknownModelFromProfileCarriesUnnamedVersion() async throws {
        let harness = ModelHarness(models: [TestModel.gigaamLike()])
        try harness.seedUserProfiles([testProfile(id: "dangling", asr: "absent-model", builtIn: false)])
        let manager = try harness.makeManager()

        do {
            _ = try await manager.missingModels(profileId: "dangling")
            XCTFail("модель вне каталога обязана дать unknownModel")
        } catch let error as ModelCatalogError {
            XCTAssertEqual(error, .unknownModel(id: "absent-model", version: ModelCatalogManager.unnamedVersion))
        }
    }

    // MARK: - П.3: свободное место на macOS — «для важного использования»

    #if os(macOS)
    func test_availableDiskBytesUsesImportantUsageCapacityOnMacOS() throws {
        let root = FileManager.default.temporaryDirectory
        let missing = root.appendingPathComponent("mee458-\(UUID().uuidString)/models/x")
        let expected = try XCTUnwrap(
            root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage)

        let actual = try XCTUnwrap(SystemMachineEnvironment().availableDiskBytes(at: missing))

        XCTAssertEqual(SystemMachineEnvironment.existingAncestor(of: missing).standardizedFileURL.path,
                       root.standardizedFileURL.path, "несуществующий каталог спрашивается у предка")
        // Том живой: между двумя чтениями место может сдвинуться — допуск 256 МиБ.
        XCTAssertLessThan(abs(actual - expected), 256 * 1024 * 1024)
    }
    #endif

    // MARK: - П.4: обратное давление (C-014 §6 п. 7)

    func test_backpressureGatePausesOnceAtHighWaterAndResumesOnceAtLowWater() {
        let gate = BackpressureGate(highWaterBytes: 100, lowWaterBytes: 30)
        var pauses = 0
        var resumes = 0

        gate.enqueued(60) { pauses += 1 }
        XCTAssertEqual(pauses, 0)
        gate.enqueued(40) { pauses += 1 }
        XCTAssertEqual(pauses, 1, "верхний порог достигнут — остановка")
        gate.enqueued(25) { pauses += 1 }   // уже вёз URLSession до остановки
        XCTAssertEqual(pauses, 1, "повторной остановки нет")
        XCTAssertTrue(gate.isPaused)

        gate.consumed(60) { resumes += 1 }
        XCTAssertEqual(resumes, 0, "65 байт в буфере — выше нижнего порога")
        gate.consumed(40) { resumes += 1 }
        XCTAssertEqual(resumes, 1, "25 байт — ниже нижнего порога, возобновление")
        gate.consumed(25) { resumes += 1 }
        XCTAssertEqual(resumes, 1)
        XCTAssertEqual(gate.bufferedBytes, 0)
        XCTAssertFalse(gate.isPaused)
    }

    /// Производитель быстрее потребителя: пока задача остановлена, новых кусков нет, и буфер
    /// не выходит за верхний порог плюс один кусок — не растёт до размера файла.
    func test_backpressureGateBoundsBufferForFastProducer() {
        let chunk = 64 * 1024
        let fileSize = 64 * 1024 * 1024
        let gate = BackpressureGate()
        var running = true
        var produced = 0
        var peak = 0
        var queue: [Int] = []

        while produced < fileSize || !queue.isEmpty {
            // Производитель: пока задача не остановлена, кладёт по четыре куска за такт.
            for _ in 0..<4 where running && produced < fileSize {
                queue.append(chunk)
                produced += chunk
                gate.enqueued(chunk) { running = false }
                peak = max(peak, gate.bufferedBytes)
            }
            // Потребитель: записывает по одному куску за такт.
            if !queue.isEmpty {
                gate.consumed(queue.removeFirst()) { running = true }
            }
        }

        XCTAssertLessThanOrEqual(peak, BackpressureGate.defaultHighWaterBytes + chunk)
        XCTAssertEqual(gate.bufferedBytes, 0)
    }
}
