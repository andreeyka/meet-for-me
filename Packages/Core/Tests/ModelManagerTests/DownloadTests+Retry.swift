//  Возврат РП `e64cbd81` по PR #177 (MEE-442), пп. 1–2 — поверх К4/К17/К22 перечня MEE-429:
//  параллельный второй `download` ждёт идущую загрузку и получает её исход (инв. 4);
//  повтор после `error(checksumMismatch)` при испорченном готовом файле начинает с нуля с
//  первого же вызова (§6 п. 6, `error → downloading` инв. 6).

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

extension DownloadTests {

    /// Стенд, где загрузка держится на первой порции, пока тест не отпустит `gate`.
    private func gatedHarness(_ id: String, content: Data? = nil) throws -> (DownloadedFixture, Probe<Bool>) {
        let model = TestModel.make(id: id, files: [("g.bin", TestModel.bytes(64, seed: 80))])
        let harness = ModelHarness(models: [model])
        if let content {
            harness.transport.setContent(content, at: model.url("g.bin"))
        }
        let gate = Probe(false)
        harness.transport.onChunk { _, index in
            guard index == 0 else { return }
            while !gate.value {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let fixture = DownloadedFixture(harness: harness, manager: try harness.makeManager(), model: model)
        return (fixture, gate)
    }

    private func startBoth(_ fixture: DownloadedFixture, _ gate: Probe<Bool>, id: String) async
        -> (Task<Void, Error>, Task<Void, Error>) {
        let manager = fixture.manager
        let first = Task { try await manager.download(id: id, version: "1.0.0") }
        while fixture.harness.transport.requests.isEmpty {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let second = Task { try await manager.download(id: id, version: "1.0.0") }
        try? await Task.sleep(nanoseconds: 50_000_000)      // второй вызов успел войти, пока первый держится
        gate.update { $0 = true }
        return (first, second)
    }

    func test_concurrentSecondDownloadWaitsForRunningOneAndSharesItsOutcome() async throws {
        let (fixture, gate) = try gatedHarness("parallel-ok")
        let manager = fixture.manager
        let (first, second) = await startBoth(fixture, gate, id: "parallel-ok")
        try await second.value
        let afterSecond = await manager.state(id: "parallel-ok", version: "1.0.0")
        XCTAssertEqual(afterSecond, .downloaded, "второй вызов вернулся только после downloaded")
        try await first.value
        XCTAssertEqual(fixture.harness.transport.requests.count, 1, "вторая загрузка не начиналась")

        // Загрузка падает — падают оба вызова, тем же исходом.
        let broken = try gatedHarness("parallel-bad", content: TestModel.bytes(64, seed: 81))
        let (badFirst, badSecond) = await startBoth(broken.0, broken.1, id: "parallel-bad")
        for task in [badFirst, badSecond] {
            do {
                try await task.value
                XCTFail("ожидался checksumMismatch у обоих вызовов")
            } catch ModelCatalogError.checksumMismatch(let name, _, _) {
                XCTAssertEqual(name, "g.bin")
            }
        }
    }

    func test_downloadAfterVerifyChecksumMismatchRestartsFromZeroOnFirstCall() async throws {
        let model = TestModel.make(id: "reverify", files: [("v.bin", TestModel.bytes(48, seed: 82)),
                                                           ("w.bin", TestModel.bytes(20, seed: 83))])
        let harness = ModelHarness(models: [model])
        let manager = try harness.makeManager()
        try await manager.download(id: "reverify", version: "1.0.0")
        let file = harness.directory(model).appendingPathComponent("v.bin")
        try TestModel.bytes(48, seed: 99).write(to: file)
        do {
            try await manager.verify(id: "reverify", version: "1.0.0")
            XCTFail("испорченный файл — verify бросает")
        } catch ModelCatalogError.checksumMismatch {
        }
        let broken = await manager.state(id: "reverify", version: "1.0.0")
        guard case .error(.checksumMismatch) = broken else {
            return XCTFail("вектор: error(checksumMismatch), получено \(broken)")
        }

        try await manager.download(id: "reverify", version: "1.0.0")
        let state = await manager.state(id: "reverify", version: "1.0.0")
        XCTAssertEqual(state, .downloaded, "первый же повторный download даёт downloaded")
        XCTAssertEqual(try Data(contentsOf: file), model.contents["v.bin"], "негодный файл скачан заново")
        XCTAssertEqual(harness.transport.requests(for: model.url("v.bin")).map(\.firstByte), [0, 0],
                       "испорченный файл — с нуля")
        XCTAssertEqual(harness.transport.requests(for: model.url("w.bin")).count, 1, "годный файл не перекачан")
    }
}
