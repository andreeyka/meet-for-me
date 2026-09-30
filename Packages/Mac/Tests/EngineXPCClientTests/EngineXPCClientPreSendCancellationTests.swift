//  EngineXPCClientPreSendCancellationTests — MEE-510, C-012 v13 §3.2 (строка «`CancellationError`,
//  брошенный `RecordingRepository.recording(id:)`, `resolve(profileId:)` или `beginUse(_:)` до
//  отправки запроса»), инв. 12, векторы v13 инв. 24; IR-154 п. 2 (MEE-493). Настоящий
//  `EngineXPCClient` поверх настоящего `NSXPCConnection` к `TestEngineXPCService` — он же
//  счётчик отправок транспорта.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientPreSendCancellationTests: XCTestCase {

    private func makeSpec() -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    /// Критерий 2: транспорт не тронут (ни `ping`, ни рабочего кадра, ни `cancel(jobId)`),
    /// расписка не выдана и не гасилась. Пауза — дать запоздалому `cancel` шанс долететь.
    private func assertNothingSent(
        _ fixture: XPCFixture, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.service.sendCount, 0, "транспорт не должен отправлять", file: file, line: line)
        XCTAssertEqual(fixture.service.receivedJobIds, [], "cancel(jobId) не шлётся", file: file, line: line)
        XCTAssertEqual(fixture.modelCatalog.beginUseSuccessCount, 0, file: file, line: line)
        XCTAssertEqual(fixture.modelCatalog.endUseCallCount, 0, "endUse без расписки", file: file, line: line)
    }

    private func assertCancelled(
        _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("ожидался cancelled", file: file, line: line)
        } catch TranscriptionServiceError.cancelled {
        } catch {
            XCTFail("ожидался cancelled, получено \(error)", file: file, line: line)
        }
    }

    private func assertModelsNotReady(
        _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("ожидался modelsNotReady", file: file, line: line)
        } catch TranscriptionServiceError.modelsNotReady(let profileId, _) {
            XCTAssertEqual(profileId, "p1", file: file, line: line)
        } catch {
            XCTFail("ожидался modelsNotReady, получено \(error)", file: file, line: line)
        }
    }

    // MARK: - Критерии 1, 2: `CancellationError` из порта до отправки → `cancelled`

    func test_v13_recordingCancellationGivesCancelled() async throws {
        let recordings = ThrowingRecordingRepository(error: CancellationError())
        let fixture = XPCFixture(recordings: recordings)
        configureReadyProfile(fixture.modelCatalog)

        await assertCancelled { _ = try await fixture.client.transcribe(self.makeSpec()) { _ in } }

        XCTAssertEqual(recordings.recordingCalls, 1)
        try await assertNothingSent(fixture)
    }

    func test_v13_embedRecordingCancellationGivesCancelled() async throws {
        let fixture = XPCFixture(recordings: ThrowingRecordingRepository(error: CancellationError()))
        configureReadyProfile(fixture.modelCatalog, embeddingModelId: "emb-1")

        await assertCancelled {
            _ = try await fixture.client.embed(recordingId: UUID(), startMs: 0, endMs: 1000, profileId: "p1")
        }
        try await assertNothingSent(fixture)
    }

    func test_v13_resolveCancellationGivesCancelled() async throws {
        let fixture = XPCFixture.transportOnly(wrapCatalog: {
            ThrowingModelCatalog(base: $0, resolveError: CancellationError())
        })
        configureReadyProfile(fixture.modelCatalog)

        await assertCancelled { _ = try await fixture.client.transcribe(self.makeSpec()) { _ in } }
        try await assertNothingSent(fixture)
    }

    func test_v13_embedResolveCancellationGivesCancelled() async throws {
        let fixture = XPCFixture.transportOnly(wrapCatalog: {
            ThrowingModelCatalog(base: $0, resolveError: CancellationError())
        })
        configureReadyProfile(fixture.modelCatalog, embeddingModelId: "emb-1")

        await assertCancelled {
            _ = try await fixture.client.embed(recordingId: UUID(), startMs: 0, endMs: 1000, profileId: "p1")
        }
        try await assertNothingSent(fixture)
    }

    func test_v13_beginUseCancellationGivesCancelledWithoutEndUse() async throws {
        let fixture = XPCFixture.transportOnly(wrapCatalog: {
            ThrowingModelCatalog(base: $0, beginUseError: CancellationError())
        })
        configureReadyProfile(fixture.modelCatalog)

        await assertCancelled { _ = try await fixture.client.transcribe(self.makeSpec()) { _ in } }
        try await assertNothingSent(fixture)
    }

    func test_v13_embedBeginUseCancellationGivesCancelledWithoutEndUse() async throws {
        let fixture = XPCFixture.transportOnly(wrapCatalog: {
            ThrowingModelCatalog(base: $0, beginUseError: CancellationError())
        })
        configureReadyProfile(fixture.modelCatalog, embeddingModelId: "emb-1")

        await assertCancelled {
            _ = try await fixture.client.embed(recordingId: UUID(), startMs: 0, endMs: 1000, profileId: "p1")
        }
        try await assertNothingSent(fixture)
    }

    // MARK: - Критерий 3: регрессионные векторы — прочие ошибки прежние

    /// `ModelCatalogError.cancelled` (C-014) — отмена загрузки моделей, не вызывающей стороны.
    func test_v13_modelCatalogCancelledFromResolveStaysModelsNotReady() async throws {
        let fixture = XPCFixture.transportOnly(wrapCatalog: {
            ThrowingModelCatalog(base: $0, resolveError: ModelCatalogError.cancelled)
        })
        configureReadyProfile(fixture.modelCatalog)

        await assertModelsNotReady { _ = try await fixture.client.transcribe(self.makeSpec()) { _ in } }
        try await assertNothingSent(fixture)
    }

    func test_v13_modelCatalogCancelledFromBeginUseStaysModelsNotReady() async throws {
        let fixture = XPCFixture.transportOnly(wrapCatalog: {
            ThrowingModelCatalog(base: $0, beginUseError: ModelCatalogError.cancelled)
        })
        configureReadyProfile(fixture.modelCatalog)

        await assertModelsNotReady { _ = try await fixture.client.transcribe(self.makeSpec()) { _ in } }
        try await assertNothingSent(fixture)
    }

    /// Правило — по типу ошибки: не-`CancellationError` из репозитория в отменённом `Task`
    /// остаётся `serviceUnavailable` (`Task.isCancelled` отмену не подменяет).
    func test_v13_otherRecordingErrorStaysServiceUnavailable() async throws {
        let recordings = ThrowingRecordingRepository(error: StorageError.io(message: "database is locked"))
        let fixture = XPCFixture(recordings: recordings)
        configureReadyProfile(fixture.modelCatalog)

        let task = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await fixture.client.transcribe(self.makeSpec()) { _ in }
                return nil
            } catch {
                return error
            }
        }
        let error = await task.value
        guard case .serviceUnavailable(let message)? = error as? TranscriptionServiceError else {
            return XCTFail("ожидался serviceUnavailable, получено \(String(describing: error))")
        }
        XCTAssertTrue(message.contains("database is locked"), message)
        try await assertNothingSent(fixture)
    }

    // MARK: - Критерий 4: сквозной — очередь отменила задачу во время `resolve`

    /// Отмену ведёт очередь (C-013 инв. 8): `JobQueueEngine` отменяет `Task`, в котором зовёт
    /// `run(_:progress:)`. Порт каталога, отменённый во время ожидания, бросает
    /// `CancellationError`; клиент даёт `cancelled`, обработчик по §4 — `.success`, а не
    /// `.retry` по `modelsNotReady` (§4.1), как было в v12.
    func test_v13_queueCancelDuringResolveGivesHandlerSuccess() async throws {
        let arrival = ArrivalFlag()
        let fixture = XPCFixture.transportOnly(wrapCatalog: {
            ThrowingModelCatalog(base: $0, suspendResolveUntilCancelled: arrival)
        })
        configureReadyProfile(fixture.modelCatalog)
        let handler = TranscribeJobHandler(port: fixture.client, transcripts: InMemoryTranscriptRepository())
        let job = Self.transcribeJob()

        let task = Task { await handler.run(job, progress: { _ in }) }
        let deadline = Date().addingTimeInterval(5)
        while !arrival.hasArrived {
            guard Date() < deadline else { return XCTFail("resolve не был вызван за 5 с") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()

        let outcome = await task.value
        XCTAssertEqual(outcome, .success)
        try await assertNothingSent(fixture)
    }

    private static func transcribeJob() -> Job {
        Job(
            id: UUID(), type: .transcribe,
            payload: .transcribe(recordingId: UUID(), profileId: "p1", language: nil),
            status: .running, priority: 0, attempts: 0, maxAttempts: 3,
            runAfter: Date(timeIntervalSince1970: 0),
            conditions: JobConditions(
                requiresACPower: false, forbidWhileRecording: false,
                maxThermalPressure: .critical, requiresProfileReady: nil
            ),
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
