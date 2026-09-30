//  TranscribeJobHandlerQueueStringTests — строки очереди `TranscribeJobHandler` (MEE-506):
//  C-012 §4 оставляет `JobOutcome.error` за обработчиком («…»), C-016 §3.1 и инв. 31 требуют,
//  чтобы строка доезжала до `facade.jobFailed` дословно. Здесь — вид строки: у случаев без
//  текста и у `modelsNotReady` — код `engine.<case>` без значений, у `recordingNotReady` —
//  сам `message` без идентификатора записи.
//
//  Место — `Core (Linux)`, способ — Т, фикстура — `FakeTranscriptionServicePort`.

import XCTest
import Foundation
@testable import DomainCore
import DomainTestKit

final class TranscribeJobHandlerQueueStringTests: XCTestCase {

    private func job() -> Job {
        Job(
            id: UUID(), type: .transcribe,
            payload: .transcribe(
                recordingId: TranscriptFixtures.oneOnOne.recordingId, profileId: "ru-default", language: nil
            ),
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

    private func queueString(_ error: TranscriptionServiceError) async -> String? {
        let port = FakeTranscriptionServicePort()
        port.forcedError = error
        let handler = TranscribeJobHandler(port: port, transcripts: InMemoryTranscriptRepository())
        switch await handler.run(job(), progress: { _ in }) {
        case .retry(_, let error), .permanentFailure(let error):
            return error
        case .success:
            return nil
        }
    }

    /// `message` `modelsNotReady` у адаптера (`EngineXPCClient`) — `"\(error)"` каталога моделей.
    private static let modelsNotReady = TranscriptionServiceError.modelsNotReady(
        profileId: "ru-default", message: "\(ModelCatalogError.notDownloaded(modelId: "gigaam-v3", version: "1"))"
    )

    /// Случаи без текста для человека и `modelsNotReady` — код §3.1 `engine.<case>`, не описание
    /// значения Swift.
    func test_casesWithoutHumanMessageWriteEngineCode() async {
        let rows: [(TranscriptionServiceError, String)] = [
            (.serviceCrashed, "engine.serviceCrashed"),
            (.timedOut(seconds: 120), "engine.timedOut"),
            (.protocolVersionMismatch(client: 1, service: 2), "engine.protocolVersionMismatch"),
            (.messageTooLarge(bytes: 33_554_432), "engine.messageTooLarge"),
            (Self.modelsNotReady, "engine.modelsNotReady")
        ]
        for (error, expected) in rows {
            let actual = await queueString(error)
            XCTAssertEqual(actual, expected, "\(error)")
        }
    }

    /// `recordingNotReady` — `message` без `recordingId`.
    func test_recordingNotReadyWritesMessageWithoutRecordingId() async {
        let recordingId = TranscriptFixtures.oneOnOne.recordingId
        let notReady = await queueString(.recordingNotReady(recordingId: recordingId, message: "записи нет"))
        XCTAssertEqual(notReady, "записи нет")
    }

    /// Сквозь фасад: инв. 31 — `AppFacadeImpl.jobFailedError(for:)` несёт строку очереди дословно
    /// (как К60-i в `FailureSourcesInv31Tests`); показанный текст — текст словаря по коду, без
    /// имени случая, скобок Swift и UUID записи.
    func test_queueStringsReachUserAsDictionaryText() async throws {
        let recordingId = TranscriptFixtures.oneOnOne.recordingId
        let rows: [(TranscriptionServiceError, String)] = [
            (.serviceCrashed, "аварийно завершилась"),
            (.timedOut(seconds: 120), "не ответила вовремя"),
            (.protocolVersionMismatch(client: 1, service: 2), "не совпадают"),
            (.messageTooLarge(bytes: 33_554_432), "слишком велик"),
            (Self.modelsNotReady, "модели для распознавания не готовы"),
            (.recordingNotReady(recordingId: recordingId, message: "записи нет"), "записи нет")
        ]
        for (error, expectedText) in rows {
            let queued = await queueString(error)
            let raw = try XCTUnwrap(queued, "\(error)")
            let jobId = UUID()
            let event = JobEvent.failed(jobId: jobId, type: .transcribe, error: raw, willRetry: false)
            let failure = try XCTUnwrap(AppFacadeImpl.jobFailedError(for: event), "\(error)")
            XCTAssertEqual(failure, .jobFailed(jobId: jobId, type: .transcribe, message: raw), "инв. 31: дословно")
            let shown = failure.view.message
            XCTAssertTrue(shown.contains(expectedText), "\(error): «\(shown)»")
            XCTAssertFalse(shown.contains(recordingId.uuidString), shown)
            XCTAssertFalse(shown.contains("("), shown)
            XCTAssertFalse(shown.contains("engine."), shown)
        }
    }
}
