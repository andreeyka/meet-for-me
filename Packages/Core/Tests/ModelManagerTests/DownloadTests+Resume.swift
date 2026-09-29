//  К18, К19, К21–К23 перечня MEE-429 (группа Д): докачка по `Range`, ответ `200` вместо `206`,
//  рассинхрон диапазона, продолжение из `paused`/`error(downloadFailed)`, запись по мере
//  поступления. Три теста §6 C-014 («Продолжение с байта L», «Сервер не поддержал диапазон»,
//  «Форма заголовка» — К20 в `DownloadTests.swift`).

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

extension DownloadTests {

    /// Модель из одного файла в 200 байт; первый запрос обрывается на 100-м байте.
    private func interruptedHarness() async throws -> DownloadedFixture {
        let model = TestModel.make(id: "resume-asr", files: [("r.bin", TestModel.bytes(200, seed: 11))])
        let harness = ModelHarness(models: [model])
        harness.transport.script(model.url("r.bin"), [.dropAfter(bytes: 100)])
        let manager = try harness.makeManager()
        do {
            try await manager.download(id: "resume-asr", version: "1.0.0")
            XCTFail("первая попытка обязана оборваться")
        } catch ModelCatalogError.downloadFailed {
        }
        let part = harness.directory(model).appendingPathComponent("r.bin.part")
        XCTAssertEqual(harness.fileSize(part), 100, "вектор: на диске .part длины L = 100")
        return DownloadedFixture(harness: harness, manager: manager, model: model)
    }

    func test_k18_resumeWithRangeHeaderContinuesPartialDownload() async throws {
        let fixture = try await interruptedHarness()
        try await fixture.manager.download(id: "resume-asr", version: "1.0.0")
        let requests = fixture.harness.transport.requests(for: fixture.model.url("r.bin"))
        XCTAssertEqual(requests.map(\.firstByte), [0, 100], "повтор пришёл с firstByte == L")
        XCTAssertEqual(requests.last?.rangeHeaderLine, "Range: bytes=100-")
        let state = await fixture.manager.state(id: "resume-asr", version: "1.0.0")
        XCTAssertEqual(state, .downloaded, "дописанный .part сошёлся по sha256")
    }

    func test_k18_noResumeDataApiUsedInModelManagerSources() throws {
        let sources = try ModelManagerSources.files()
        XCTAssertFalse(sources.isEmpty, "вектор непустоты: исходники ModelManager найдены")
        for source in sources {
            let code = ModelManagerSources.code(source.text)
            for token in ["resumeData", "withResumeData", "byProducingResumeData"] {
                XCTAssertFalse(code.contains(token), "\(source.name): \(token)")
            }
        }
        XCTAssertTrue(sources.contains { $0.text.contains("bytes=\\(firstByte)-") }, "механизм — Range")
    }

    func test_k19_serverIgnoresRangeRestartsFromZero() async throws {
        let fixture = try await interruptedHarness()
        let url = fixture.model.url("r.bin")
        fixture.harness.transport.script(url, [.ignoreRange])
        try await fixture.manager.download(id: "resume-asr", version: "1.0.0")
        XCTAssertEqual(fixture.harness.transport.requests(for: url).map(\.firstByte), [0, 100])
        let final = fixture.harness.directory(fixture.model).appendingPathComponent("r.bin")
        XCTAssertEqual(try Data(contentsOf: final), fixture.model.contents["r.bin"], "файл переписан с нуля")
        let state = await fixture.manager.state(id: "resume-asr", version: "1.0.0")
        XCTAssertEqual(state, .downloaded, "не ошибка — итог валидная модель")
    }

    func test_k21_rangeMismatchRestartsOnceThenFailsPermanently() async throws {
        // Рассинхрон один раз — перезапуск файла с нуля, итог валиден.
        let once = try await interruptedHarness()
        let url = once.model.url("r.bin")
        once.harness.transport.script(url, [.respond(status: 206, firstByte: 50, body: TestModel.bytes(150, seed: 1))])
        try await once.manager.download(id: "resume-asr", version: "1.0.0")
        XCTAssertEqual(once.harness.transport.requests(for: url).map(\.firstByte), [0, 100, 0])
        let onceState = await once.manager.state(id: "resume-asr", version: "1.0.0")
        XCTAssertEqual(onceState, .downloaded)

        // Рассинхрон повторно — downloadFailed, без бесконечного цикла.
        let twice = try await interruptedHarness()
        twice.harness.transport.script(url, [
            .respond(status: 206, firstByte: 50, body: Data([1, 2, 3])),
            .respond(status: 416, firstByte: nil, body: Data())
        ])
        do {
            try await twice.manager.download(id: "resume-asr", version: "1.0.0")
            XCTFail("ожидался downloadFailed")
        } catch ModelCatalogError.downloadFailed {
        }
        XCTAssertEqual(twice.harness.transport.requests(for: url).map(\.firstByte), [0, 100, 0], "ровно один рестарт")
        let state = await twice.manager.state(id: "resume-asr", version: "1.0.0")
        guard case .error(.downloadFailed) = state else {
            return XCTFail("ожидалось error(downloadFailed), получено \(state)")
        }
    }

    func test_k22_pausedOrFailedDownloadResumesFromExistingPart() async throws {
        // Вектор paused.
        let paused = try await interruptedHarness()
        let pausedState = await paused.manager.state(id: "resume-asr", version: "1.0.0")
        XCTAssertEqual(pausedState, .paused(bytesOnDisk: 100))
        try await paused.manager.download(id: "resume-asr", version: "1.0.0")
        XCTAssertEqual(paused.harness.transport.requests.map(\.firstByte), [0, 100])

        // Вектор error(downloadFailed): отказ сервера кодом ответа, .part сохранён.
        let failed = try await interruptedHarness()
        let url = failed.model.url("r.bin")
        failed.harness.transport.script(url, [.respond(status: 503, firstByte: nil, body: Data())])
        do {
            try await failed.manager.download(id: "resume-asr", version: "1.0.0")
            XCTFail("ожидался downloadFailed")
        } catch ModelCatalogError.downloadFailed {
        }
        let failedState = await failed.manager.state(id: "resume-asr", version: "1.0.0")
        guard case .error(.downloadFailed) = failedState else {
            return XCTFail("ожидалось error(downloadFailed), получено \(failedState)")
        }
        try await failed.manager.download(id: "resume-asr", version: "1.0.0")
        XCTAssertEqual(failed.harness.transport.requests(for: url).map(\.firstByte), [0, 100, 100],
                       "из error(downloadFailed) — продолжение с текущей длины .part")
        let finalState = await failed.manager.state(id: "resume-asr", version: "1.0.0")
        XCTAssertEqual(finalState, .downloaded)
    }

    func test_k23_partFileGrowsOnDiskBetweenReceiveChunks() async throws {
        let model = TestModel.make(id: "stream-asr", files: [("s.bin", TestModel.bytes(100, seed: 12))])
        let harness = ModelHarness(models: [model])
        harness.transport.chunkSize = 16
        let part = harness.directory(model).appendingPathComponent("s.bin.part")
        let sizes = Probe<[Int64]>([])
        harness.transport.onChunk { _, _ in
            let attributes = try? FileManager.default.attributesOfItem(atPath: part.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            sizes.update { $0.append(size) }
        }
        let manager = try harness.makeManager()
        try await manager.download(id: "stream-asr", version: "1.0.0")
        XCTAssertEqual(sizes.value, [16, 32, 48, 64, 80, 96, 100], "длина .part на диске растёт с каждой порцией")
    }
}
