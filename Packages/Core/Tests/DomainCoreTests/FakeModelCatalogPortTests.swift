//  FakeModelCatalogPort — тесты «Готовности» MEE-395: счётчик `endUse` (инвариант 23),
//  отказы `resolve`/`beginUse` (в т.ч. атомарность инварианта 22), плюс инвариант 19
//  (`resolve` выдаёт существующий на диске каталог) и §4.2 (`paused`/`diskUsage`
//  согласованы одной и той же величиной). Остальные методы — попутной санитарной
//  проверкой, не предметом задачи.
//
//  Границы фейка (см. заголовок `FakeModelCatalogPort.swift`) здесь не проверяются как
//  утверждения о порте — они устройство фейка, а не поведение, которое обязан
//  воспроизводить реализатор.

import XCTest
import DomainCore
import DomainTestKit

final class FakeModelCatalogPortTests: XCTestCase {

    // MARK: - Санитарная проверка каталога

    func test_mee395_setCatalogIsReflectedByModelsAndModelLookup() async {
        let port = FakeModelCatalogPort()
        let asr = descriptor(id: "asr-1")
        port.setCatalog([asr])

        let all = await port.models()
        XCTAssertEqual(all, [asr])

        let found = await port.model(id: "asr-1", version: "1.0.0")
        XCTAssertEqual(found, asr)

        let notFound = await port.model(id: "asr-1", version: "9.9.9")
        XCTAssertNil(notFound)
    }

    func test_mee395_stateDefaultsToAvailableForUnknownModel() async {
        let port = FakeModelCatalogPort()
        let state = await port.state(id: "nope", version: "1.0.0")
        XCTAssertEqual(state, .available)
    }

    func test_mee395_downloadMarksDownloadedUnlessFailureForced() async throws {
        let port = FakeModelCatalogPort()
        port.setCatalog([descriptor(id: "asr-1")])

        try await port.download(id: "asr-1", version: "1.0.0")
        let state = await port.state(id: "asr-1", version: "1.0.0")
        XCTAssertEqual(state, .downloaded)

        port.failDownload(.downloadFailed(message: "сеть недоступна"), forId: "asr-1", version: "2.0.0")
        do {
            try await port.download(id: "asr-1", version: "2.0.0")
            XCTFail("должен бросить заданную ошибку")
        } catch ModelCatalogError.downloadFailed(let message) {
            XCTAssertEqual(message, "сеть недоступна")
        }
    }

    /// §4.2: `bytesOnDisk` — одна и та же величина в `downloading(fraction:)`, `paused` и
    /// `diskUsage()`. `cancelDownload` строит `paused` из текущей `downloading(fraction:)`
    /// той же формулой (`fraction * sizeBytes`), и `diskUsage()` отдаёт то же число.
    func test_mee395_pausedBytesMatchDownloadingFractionPerSection42() async {
        let port = FakeModelCatalogPort()
        port.setCatalog([descriptor(id: "asr-1", sizeBytes: 1000)])
        port.setState(.downloading(fraction: 0.4), forId: "asr-1", version: "1.0.0")

        await port.cancelDownload(id: "asr-1", version: "1.0.0")

        let state = await port.state(id: "asr-1", version: "1.0.0")
        guard case .paused(let bytesOnDisk) = state else {
            return XCTFail("ожидался .paused после cancelDownload, получено \(state)")
        }
        XCTAssertEqual(bytesOnDisk, 400, "§4.2: bytesOnDisk = fraction * sizeBytes")

        let usage = await port.diskUsage()
        XCTAssertEqual(usage.first(where: { $0.modelId == "asr-1" })?.bytesOnDisk, 400,
                       "diskUsage() согласован с paused по той же величине")
    }

    func test_mee395_deleteThrowsForcedErrorAndOtherwiseResetsToAvailable() async throws {
        let port = FakeModelCatalogPort()
        port.setCatalog([descriptor(id: "asr-1")])
        port.setState(.downloaded, forId: "asr-1", version: "1.0.0")

        port.failDelete(.modelInUseByProfile(modelId: "asr-1", profileIds: ["p1"]), forId: "asr-1", version: "1.0.0")
        do {
            try await port.delete(id: "asr-1", version: "1.0.0")
            XCTFail("должен бросить заданную ошибку")
        } catch ModelCatalogError.modelInUseByProfile(let modelId, let profileIds) {
            XCTAssertEqual(modelId, "asr-1")
            XCTAssertEqual(profileIds, ["p1"])
        }

        port.failDelete(nil, forId: "asr-1", version: "1.0.0")
        try await port.delete(id: "asr-1", version: "1.0.0")
        let state = await port.state(id: "asr-1", version: "1.0.0")
        XCTAssertEqual(state, .available)
    }

    // MARK: - beginUse / endUse (инварианты 22, 23) — предмет «Готовности»

    /// Инвариант 22: атомарна. Из двух бандлов один `.downloaded`, другой — нет: весь набор
    /// отказывает, и УСПЕШНАЯ половина не помечается — не переходит в `.loaded`.
    func test_mee395_beginUseFailsAtomicallyWhenAnyBundleNotDownloaded() async throws {
        let port = FakeModelCatalogPort()
        port.setCatalog([descriptor(id: "asr-1"), descriptor(id: "vad-1")])
        port.setState(.downloaded, forId: "asr-1", version: "1.0.0")
        // vad-1 остаётся .available — не downloaded.

        let asrBundle = bundle(modelId: "asr-1", role: .asr)
        let vadBundle = bundle(modelId: "vad-1", role: .vad)

        do {
            _ = try await port.beginUse([asrBundle, vadBundle])
            XCTFail("должен бросить notDownloaded")
        } catch ModelCatalogError.notDownloaded(let modelId, let version) {
            XCTAssertEqual(modelId, "vad-1")
            XCTAssertEqual(version, "1.0.0")
        }

        let asrState = await port.state(id: "asr-1", version: "1.0.0")
        XCTAssertEqual(asrState, .downloaded, "атомарность: успешная половина набора не помечена .loaded")
        XCTAssertEqual(port.beginUseSuccessCount, 0)
    }

    func test_mee395_beginUseSucceedsAndReportsLoadedState() async throws {
        let port = FakeModelCatalogPort()
        port.setCatalog([descriptor(id: "asr-1")])
        port.setState(.downloaded, forId: "asr-1", version: "1.0.0")

        let token = try await port.beginUse([bundle(modelId: "asr-1", role: .asr)])

        XCTAssertEqual(port.beginUseSuccessCount, 1)
        XCTAssertEqual(port.outstandingUseTokenCount, 1)
        let state = await port.state(id: "asr-1", version: "1.0.0")
        XCTAssertEqual(state, .loaded)

        await port.endUse(token)
        XCTAssertEqual(port.outstandingUseTokenCount, 0)
    }

    func test_mee395_forcedBeginUseErrorOverridesNaturalCheck() async {
        let port = FakeModelCatalogPort()
        port.setCatalog([descriptor(id: "asr-1")])
        port.setState(.downloaded, forId: "asr-1", version: "1.0.0")
        port.forcedBeginUseError = .insufficientDiskSpace(requiredBytes: 10, availableBytes: 1)

        do {
            _ = try await port.beginUse([bundle(modelId: "asr-1", role: .asr)])
            XCTFail("должен бросить заданную ошибку, а не notDownloaded")
        } catch ModelCatalogError.insufficientDiskSpace(let required, let available) {
            XCTAssertEqual(required, 10)
            XCTAssertEqual(available, 1)
        } catch {
            XCTFail("неверная ошибка: \(error)")
        }
    }

    /// Инвариант 23: идемпотентна. Повторное погашение той же расписки и погашение
    /// неизвестной расписки — БЕЗ ЭФФЕКТА, но фейк честно считает КАЖДЫЙ звонок отдельно от
    /// числа звонков, которые реально что-то погасили (§«Фейк для тестов»: «тест вправе
    /// проверить, что потребитель погасил ровно столько, сколько взял»).
    func test_mee395_endUseCounterIsIdempotentOnRepeatedAndUnknownTokens() async throws {
        let port = FakeModelCatalogPort()
        port.setCatalog([descriptor(id: "asr-1")])
        port.setState(.downloaded, forId: "asr-1", version: "1.0.0")
        let token = try await port.beginUse([bundle(modelId: "asr-1", role: .asr)])

        await port.endUse(token)
        XCTAssertEqual(port.endUseCallCount, 1)
        XCTAssertEqual(port.endUseEffectiveCount, 1)
        XCTAssertEqual(port.outstandingUseTokenCount, 0)
        let afterFirstEnd = await port.state(id: "asr-1", version: "1.0.0")
        XCTAssertEqual(afterFirstEnd, .downloaded, "счётчик расписок обнулился — состояние вернулось к downloaded")

        await port.endUse(token)
        XCTAssertEqual(port.endUseCallCount, 2, "повторный вызов учтён — звонок был")
        XCTAssertEqual(port.endUseEffectiveCount, 1, "но эффекта не было — уже погашена")

        await port.endUse(ModelUseToken(rawValue: UUID()))
        XCTAssertEqual(port.endUseCallCount, 3, "звонок на неизвестную расписку тоже учтён")
        XCTAssertEqual(port.endUseEffectiveCount, 1, "но тоже без эффекта")
    }

    // MARK: - resolve (инвариант 19) — предмет «Готовности»

    func test_mee395_resolveThrowsUnknownProfileWhenNotRegistered() async {
        let port = FakeModelCatalogPort()
        do {
            _ = try await port.resolve(profileId: "missing")
            XCTFail("должен бросить unknownProfile")
        } catch ModelCatalogError.unknownProfile(let id) {
            XCTAssertEqual(id, "missing")
        } catch {
            XCTFail("неверная ошибка: \(error)")
        }
    }

    func test_mee395_resolveThrowsForcedError() async {
        let port = FakeModelCatalogPort()
        port.setProfiles([profile(id: "p1", asrModelId: "asr-1")])
        port.failResolve(.manifestUnreachable(message: "нет сети"), forProfileId: "p1")

        do {
            _ = try await port.resolve(profileId: "p1")
            XCTFail("должен бросить заданную ошибку")
        } catch ModelCatalogError.manifestUnreachable(let message) {
            XCTAssertEqual(message, "нет сети")
        } catch {
            XCTFail("неверная ошибка: \(error)")
        }
    }

    /// Инвариант 19: `ModelBundle.directoryURL`, выданный `resolve`, существует на диске в
    /// момент выдачи и содержит все файлы `ModelDescriptor.files`.
    func test_mee395_resolveProducesBundleWithExistingFilesOnDisk() async throws {
        let port = FakeModelCatalogPort()
        let file = ModelFile(
            name: "weights.bin",
            url: URL(string: "https://cdn.example.com/weights.bin")!,
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 500
        )
        port.setCatalog([descriptor(id: "asr-1", files: [file])])
        port.setProfiles([profile(id: "p1", asrModelId: "asr-1")])

        let resolved = try await port.resolve(profileId: "p1")

        XCTAssertEqual(resolved.asr.modelId, "asr-1")
        var isDirectory: ObjCBool = false
        let directoryExists = FileManager.default.fileExists(
            atPath: resolved.asr.directoryURL.path, isDirectory: &isDirectory
        )
        XCTAssertTrue(directoryExists && isDirectory.boolValue, "инвариант 19: каталог существует")
        let fileExists = FileManager.default.fileExists(
            atPath: resolved.asr.directoryURL.appendingPathComponent("weights.bin").path
        )
        XCTAssertTrue(fileExists, "инвариант 19: файл модели присутствует в момент выдачи")
    }

    // MARK: - missingModels (существующий метод, сохранён)

    func test_mee395_missingModelsReturnsOnlyModelsNotYetDownloaded() async throws {
        let port = FakeModelCatalogPort()
        port.setCatalog([descriptor(id: "asr-1"), descriptor(id: "vad-1")])
        port.setState(.downloaded, forId: "asr-1", version: "1.0.0")
        // vad-1 остаётся .available.
        port.setProfiles([profile(id: "p1", asrModelId: "asr-1", vadModelId: "vad-1")])

        let missing = try await port.missingModels(profileId: "p1")

        XCTAssertEqual(missing.map(\.id), ["vad-1"])
    }

    // MARK: - events()

    func test_mee395_eventsStreamReceivesManuallyPushedEventsAndFinishes() async {
        let port = FakeModelCatalogPort()
        var iterator = port.events().makeAsyncIterator()

        port.pushEvent(.catalogRefreshed(modelCount: 3))
        let received = await iterator.next()
        XCTAssertEqual(received, .catalogRefreshed(modelCount: 3))

        port.finishEvents()
        let final = await iterator.next()
        XCTAssertNil(final, "finishEvents() завершает поток")
    }
}

// MARK: - Построители фикстур

private func descriptor(
    id: String,
    version: String = "1.0.0",
    sizeBytes: Int64 = 1000,
    files: [ModelFile] = []
) -> ModelDescriptor {
    ModelDescriptor(
        id: id,
        version: version,
        role: .asr,
        engine: "fluidaudio",
        runtime: .coreml,
        displayName: id,
        description: "",
        sizeBytes: sizeBytes,
        languages: ["ru"],
        files: files,
        quantization: nil,
        minChip: .m1,
        minRAMGB: 4,
        recommendedFor: []
    )
}

private func profile(
    id: String,
    asrModelId: String,
    vadModelId: String? = nil,
    diarizationModelId: String? = nil,
    embeddingModelId: String? = nil
) -> TranscriptionProfile {
    TranscriptionProfile(
        id: id,
        displayName: id,
        language: "ru",
        asrModelId: asrModelId,
        vadModelId: vadModelId,
        diarizationModelId: diarizationModelId,
        embeddingModelId: embeddingModelId,
        diarization: DiarizationParameters(expectedSpeakers: nil, clusteringThreshold: 0.5, minSegmentMs: 500),
        isBuiltIn: false
    )
}

private func bundle(modelId: String, version: String = "1.0.0", role: ModelRole) -> ModelBundle {
    ModelBundle(
        modelId: modelId, version: version, role: role, runtime: .coreml,
        directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
    )
}
