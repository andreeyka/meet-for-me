//  EngineXPCClientCancelRaceTests — MEE-451, добор по сверке QA (MEE-389, `bfbd0b51`):
//  К27 второй вход (гонка: результат уже у клиента, отмена приходит позже — исход обычный)
//  и К53 путь (iii) (`endUse` ровно один раз после `Task.cancel()` — и для `transcribe`, и
//  для `embed`). Настоящий `EngineXPCClient` поверх `NSXPCListener.anonymous()`.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientCancelRaceTests: XCTestCase {

    private func makeSpec() -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    /// Опрос условия с пределом — вместо голого `Task.sleep` на «должно успеть».
    private func waitUntil(
        _ seconds: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("условие не выполнилось за \(seconds) с", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - К27, второй вход: результат пришёл раньше, чем отмена

    /// Гонка К27 в наблюдаемой клиентом форме: финальный `EngineReply.transcript` уже
    /// разобран и резолвил ожидание (клиент стоит в `endUse` — он зовётся только после
    /// того, как тело с круговым обменом вернуло значение), и только тогда вызывается
    /// `Task.cancel()`. Исход — обычный `Transcript`, не `.cancelled`; кадр `cancel` на
    /// сервис не уходит вовсе (тот же `jobId` на сервисе ровно один раз — сам `transcribe`).
    func test_k27_cancelAfterResultArrivedStillReturnsNormalResult() async throws {
        let gate = EndUseGate()
        let fixture = XPCFixture.transportOnly(wrapCatalog: { GatedEndUseCatalog(base: $0, gate: gate) })
        configureReadyProfile(fixture.modelCatalog)

        let task = Task {
            try await fixture.client.transcribe(self.makeSpec()) { _ in }
        }
        try await waitUntil { gate.hasArrived }
        task.cancel()
        gate.open()

        let transcript = try await task.value
        XCTAssertEqual(transcript.engine, "fake-transcription")

        try await Task.sleep(nanoseconds: 200_000_000)   // дать запоздалому cancel шанс долететь
        let jobId = try XCTUnwrap(fixture.service.receivedJobIds.first)
        XCTAssertEqual(fixture.service.receivedJobIds.filter { $0 == jobId }.count, 1,
                       "отмена после результата не должна слать кадр cancel")
        XCTAssertEqual(fixture.modelCatalog.endUseCallCount, 1)
    }

    // MARK: - К53, путь (iii): отмена Task гасит расписку ровно один раз

    func test_k53_transcribeTaskCancelReleasesModelUseTokenExactlyOnce() async throws {
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 2_000_000_000
        let fixture = XPCFixture.transportOnly(service: TestEngineXPCService(transcription: engine))
        configureReadyProfile(fixture.modelCatalog)

        let task = Task {
            try await fixture.client.transcribe(self.makeSpec()) { _ in }
        }
        try await waitUntil { !fixture.service.receivedJobIds.isEmpty }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("ожидался cancelled")
        } catch TranscriptionServiceError.cancelled {
            // ожидаемо — К28
        }
        XCTAssertEqual(fixture.modelCatalog.beginUseSuccessCount, 1)
        XCTAssertEqual(fixture.modelCatalog.endUseCallCount, 1)
        XCTAssertEqual(fixture.modelCatalog.endUseEffectiveCount, 1)
    }

    func test_k53_embedTaskCancelReleasesModelUseTokenExactlyOnce() async throws {
        let fixture = XPCFixture.transportOnly(service: TestEngineXPCService(embedding: SlowEmbeddingEngine()))
        configureReadyProfile(fixture.modelCatalog, embeddingModelId: "emb-1")

        let task = Task {
            try await fixture.client.embed(recordingId: UUID(), startMs: 0, endMs: 1000, profileId: "p1")
        }
        try await waitUntil { !fixture.service.receivedJobIds.isEmpty }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("ожидался cancelled")
        } catch TranscriptionServiceError.cancelled {
            // ожидаемо — К28
        }
        XCTAssertEqual(fixture.modelCatalog.beginUseSuccessCount, 1)
        XCTAssertEqual(fixture.modelCatalog.endUseCallCount, 1)
        XCTAssertEqual(fixture.modelCatalog.endUseEffectiveCount, 1)
    }
}

// MARK: - Фикстуры

/// `FakeEmbeddingEngine` отвечает мгновенно — отменять нечего. Этот ждёт 2 с кооперативно.
private final class SlowEmbeddingEngine: EmbeddingEngine, Sendable {
    let engineId = "slow-embedding"
    let dimension = 3
    let modelVersion = "slow-1.0"

    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResult {
        do {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
            throw EngineError.cancelled
        }
        return try EmbeddingResult(vector: [0, 0, 1], dimension: dimension, modelVersion: modelVersion)
    }
}

/// Задвижка в `endUse`: отмечает приход и держит вызов, пока тест не откроет.
private final class EndUseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = false
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    var hasArrived: Bool {
        lock.lock(); defer { lock.unlock() }
        return arrived
    }

    func arriveAndWait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrived = true
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }
}

/// `ModelCatalogPort`, делегирующий всё `FakeModelCatalogPort`, кроме задвижки перед `endUse`.
private final class GatedEndUseCatalog: ModelCatalogPort, Sendable {
    private let base: FakeModelCatalogPort
    private let gate: EndUseGate

    init(base: FakeModelCatalogPort, gate: EndUseGate) {
        self.base = base
        self.gate = gate
    }

    func endUse(_ token: ModelUseToken) async {
        await gate.arriveAndWait()
        await base.endUse(token)
    }

    func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken { try await base.beginUse(bundles) }
    func resolve(profileId: String) async throws -> ResolvedProfile { try await base.resolve(profileId: profileId) }
    func refreshCatalog() async throws { try await base.refreshCatalog() }
    func models() async -> [ModelDescriptor] { await base.models() }
    func model(id: String, version: String) async -> ModelDescriptor? { await base.model(id: id, version: version) }
    func state(id: String, version: String) async -> ModelState { await base.state(id: id, version: version) }
    func download(id: String, version: String) async throws { try await base.download(id: id, version: version) }
    func cancelDownload(id: String, version: String) async { await base.cancelDownload(id: id, version: version) }
    func verify(id: String, version: String) async throws { try await base.verify(id: id, version: version) }
    func delete(id: String, version: String) async throws { try await base.delete(id: id, version: version) }
    func diskUsage() async -> [ModelDiskUsage] { await base.diskUsage() }
    func profiles() async -> [TranscriptionProfile] { await base.profiles() }
    func saveProfile(_ profile: TranscriptionProfile) async throws { try await base.saveProfile(profile) }
    func deleteProfile(id: String) async throws { try await base.deleteProfile(id: id) }
    func missingModels(profileId: String) async throws -> [ModelDescriptor] {
        try await base.missingModels(profileId: profileId)
    }
    func events() -> AsyncStream<ModelCatalogEvent> { base.events() }
}
