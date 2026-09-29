//  Прогоны К46: каждый повторяет вход критерия-источника (К17, К22, К26, К32/К34, К47, К48)
//  на свежем стенде и возвращает переходы, наблюдённые ТОЛЬКО по `events()` (подписка до
//  действия). Плюс `verify` на испорченном файле — источник `downloaded → error`.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

struct ScenarioRun {
    let name: String
    let transitions: [String]
}

extension StateTransitionsTests {

    typealias Scenario = () async throws -> ScenarioRun

    /// Стенд с одной моделью из одного файла в 64 байта.
    static func stand(_ id: String) throws -> DownloadedFixture {
        let model = TestModel.make(id: id, files: [("f.bin", TestModel.bytes(64, seed: 70))])
        let harness = ModelHarness(models: [model])
        harness.transport.chunkSize = 16
        return DownloadedFixture(harness: harness, manager: try harness.makeManager(), model: model)
    }

    /// Подписка, действие, переходы модели `id` по событиям.
    private static func observe(_ name: String, _ manager: ModelCatalogManager, _ id: String,
                                _ action: () async throws -> Void) async throws -> ScenarioRun {
        let initial = await manager.state(id: id, version: "1.0.0")
        let recorder = EventRecorder(manager.events())
        try await action()
        let final = await manager.state(id: id, version: "1.0.0")
        await recorder.settle { events in
            recorder.states(of: id).last.map(Self.name) == Self.name(final) || events.isEmpty && initial == final
        }
        return ScenarioRun(name: name, transitions: transitions(from: initial, recorder.states(of: id)))
    }

    static var scenarios: [Scenario] {
        [downloadSucceeds, downloadMismatch, cancelBeforeFirstByte, cancelAfterFirstByte,
         resumeFromPausedThenDelete, resumeFromFailedThenDeleteError, loadedCycleThenDelete]
    }

    /// К17, первый вектор: available → downloading → downloaded.
    private static func downloadSucceeds() async throws -> ScenarioRun {
        let fixture = try Self.stand("s-ok")
        let manager = fixture.manager
        return try await observe("К17 успех", manager, "s-ok") {
            try await manager.download(id: "s-ok", version: "1.0.0")
        }
    }

    /// К17, второй вектор: downloading → error(checksumMismatch); затем К48: error → available.
    private static func downloadMismatch() async throws -> ScenarioRun {
        let fixture = try Self.stand("s-bad")
        let harness = fixture.harness
        let manager = fixture.manager
        let model = fixture.model
        harness.transport.setContent(TestModel.bytes(64, seed: 71), at: model.url("f.bin"))
        return try await observe("К17 sha256 / К48 из error", manager, "s-bad") {
            _ = try? await manager.download(id: "s-bad", version: "1.0.0")
            try await manager.delete(id: "s-bad", version: "1.0.0")
        }
    }

    /// К26: downloading → available (отмена до первого байта).
    private static func cancelBeforeFirstByte() async throws -> ScenarioRun {
        let fixture = try Self.stand("s-early")
        let harness = fixture.harness
        let manager = fixture.manager
        let model = fixture.model
        harness.transport.script(model.url("f.bin"), [.waitForCancellation])
        return try await observe("К26", manager, "s-early") {
            let task = Task { try await manager.download(id: "s-early", version: "1.0.0") }
            while harness.transport.requests.isEmpty {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            await manager.cancelDownload(id: "s-early", version: "1.0.0")
            _ = try? await task.value
        }
    }

    /// К47: downloading → paused (отмена после первого байта).
    private static func cancelAfterFirstByte() async throws -> ScenarioRun {
        let fixture = try Self.stand("s-late")
        let harness = fixture.harness
        let manager = fixture.manager
        harness.transport.onChunk { _, index in
            if index == 0 {
                await manager.cancelDownload(id: "s-late", version: "1.0.0")
            }
        }
        return try await observe("К47", manager, "s-late") {
            _ = try? await manager.download(id: "s-late", version: "1.0.0")
        }
    }

    /// К22 (paused): paused → downloading → downloaded; затем К48: downloaded → available,
    /// и ещё раз до паузы — paused → available.
    private static func resumeFromPausedThenDelete() async throws -> ScenarioRun {
        let fixture = try Self.stand("s-paused")
        let harness = fixture.harness
        let manager = fixture.manager
        let model = fixture.model
        harness.transport.script(model.url("f.bin"), [.dropAfter(bytes: 20)])
        _ = try? await manager.download(id: "s-paused", version: "1.0.0")
        return try await observe("К22 paused / К48", manager, "s-paused") {
            try await manager.download(id: "s-paused", version: "1.0.0")
            try await manager.delete(id: "s-paused", version: "1.0.0")
            harness.transport.script(model.url("f.bin"), [.dropAfter(bytes: 20)])
            _ = try? await manager.download(id: "s-paused", version: "1.0.0")
            try await manager.delete(id: "s-paused", version: "1.0.0")
        }
    }

    /// К22 (error(downloadFailed)): error → downloading → downloaded; `verify` на испорченном
    /// файле — downloaded → error.
    private static func resumeFromFailedThenDeleteError() async throws -> ScenarioRun {
        let fixture = try Self.stand("s-failed")
        let harness = fixture.harness
        let manager = fixture.manager
        let model = fixture.model
        harness.transport.script(model.url("f.bin"), [.dropAfter(bytes: 20),
                                                      .respond(status: 503, firstByte: nil, body: Data())])
        _ = try? await manager.download(id: "s-failed", version: "1.0.0")
        _ = try? await manager.download(id: "s-failed", version: "1.0.0")
        return try await observe("К22 error / verify", manager, "s-failed") {
            try await manager.download(id: "s-failed", version: "1.0.0")
            try TestModel.bytes(64, seed: 72).write(to: harness.directory(model).appendingPathComponent("f.bin"))
            _ = try? await manager.verify(id: "s-failed", version: "1.0.0")
        }
    }

    /// К32/К34: downloaded → loaded → downloaded.
    private static func loadedCycleThenDelete() async throws -> ScenarioRun {
        let fixture = try Self.stand("s-use")
        let harness = fixture.harness
        let manager = fixture.manager
        let model = fixture.model
        try await manager.download(id: "s-use", version: "1.0.0")
        let bundle = ModelBundle(modelId: "s-use", version: "1.0.0", role: .asr, runtime: .onnx,
                                 directoryURL: harness.directory(model))
        return try await observe("К32/К34", manager, "s-use") {
            let first = try await manager.beginUse([bundle])
            let second = try await manager.beginUse([bundle])
            await manager.endUse(first)
            await manager.endUse(first)
            await manager.endUse(second)
        }
    }
}

extension StateTransitionsTests {

    /// Три различающих входа инв. 6, от противного: переход вне списка не наблюдается.
    /// Код ошибки, которым вход отказывает, контракт не называет — здесь не утверждается.
    func assertForbiddenInputsProduceNoTransition() async throws {
        let fixture = try Self.stand("s-forbidden")
        let manager = fixture.manager
        try await manager.download(id: "s-forbidden", version: "1.0.0")
        let recorder = EventRecorder(manager.events())

        await manager.cancelDownload(id: "s-forbidden", version: "1.0.0")      // downloaded ↛ paused
        try await manager.download(id: "s-forbidden", version: "1.0.0")       // downloaded ↛ downloading
        let bundle = ModelBundle(modelId: "s-forbidden", version: "1.0.0", role: .asr, runtime: .onnx,
                                 directoryURL: fixture.harness.directory(fixture.model))
        let token = try await manager.beginUse([bundle])
        do {                                                                   // loaded ↛ available
            try await manager.delete(id: "s-forbidden", version: "1.0.0")
            XCTFail("delete на loaded обязан отказать")
        } catch let error as ModelCatalogError {
            // v7, инв. 11: ни один профиль модель не разрешает — свой код `modelInUse`.
            XCTAssertEqual(error, .modelInUse(modelId: "s-forbidden", version: "1.0.0"))
        }
        let whileLoaded = await manager.state(id: "s-forbidden", version: "1.0.0")
        XCTAssertEqual(whileLoaded, .loaded, "delete на loaded не перевёл модель в available")
        await manager.endUse(token)
        await recorder.settle { $0.count >= 2 }

        let states = recorder.states(of: "s-forbidden")
        XCTAssertEqual(states, [.loaded, .downloaded],
                       "только переходы расписки; ни paused, ни downloading, ни available")
        XCTAssertTrue(fixture.harness.exists(fixture.harness.directory(fixture.model)), "файлы на месте")
    }
}
