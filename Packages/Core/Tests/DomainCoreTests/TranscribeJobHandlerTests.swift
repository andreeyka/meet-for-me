//  TranscribeJobHandlerTests — К43, К44, К45, К47 перечня MEE-370 (C-012 v9 §4/§4.1,
//  инварианты 19, 20, 22), владелец: DEV-2. Найдено приёмкой #111/MEE-390, реализовано
//  и покрыто здесь (MEE-394) — обработчик физически лежит в `domain-core`, контракт §4
//  дословно объясняет почему (см. шапку `TranscribeJobHandler.swift`).
//
//  Место — `Core (Linux)`, способ — Т, фикстура — `FakeTranscriptionServicePort`.

import XCTest
import Foundation
import DomainCore
import DomainTestKit

final class TranscribeJobHandlerTests: XCTestCase {

    // MARK: - Оснастка

    private func job(attempts: Int = 0) -> Job {
        Job(
            id: UUID(),
            type: .transcribe,
            payload: .transcribe(recordingId: UUID(), profileId: "ru-default", language: nil),
            status: .running,
            priority: 0,
            attempts: attempts,
            maxAttempts: 3,
            runAfter: Date(timeIntervalSince1970: 0),
            conditions: JobConditions(
                requiresACPower: false, forbidWhileRecording: false,
                maxThermalPressure: .critical, requiresProfileReady: nil
            ),
            dedupKey: nil,
            leaseExpiresAt: nil,
            attemptStartedAt: nil,
            lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func run(
        _ error: TranscriptionServiceError, attempts: Int = 0
    ) async -> JobOutcome {
        let port = FakeTranscriptionServicePort()
        port.forcedError = error
        let handler = TranscribeJobHandler(port: port)
        return await handler.run(job(attempts: attempts), progress: { _ in })
    }

    private func assertRetry(
        _ outcome: JobOutcome, after seconds: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .retry(let after, _) = outcome else {
            return XCTFail("ожидался .retry, получено \(outcome)", file: file, line: line)
        }
        XCTAssertEqual(after, seconds, file: file, line: line)
    }

    private func assertPermanentFailure(
        _ outcome: JobOutcome, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .permanentFailure = outcome else {
            return XCTFail("ожидался .permanentFailure, получено \(outcome)", file: file, line: line)
        }
    }

    // MARK: - К43 (C-012 §4, строки транспорта)

    func test_k43_retryTableTransportErrorsToJobOutcome() async {
        assertRetry(await run(.serviceCrashed), after: 30)
        assertRetry(await run(.serviceUnavailable(message: "x")), after: 30)
        assertRetry(await run(.timedOut(seconds: 120)), after: 30)
        assertPermanentFailure(await run(.protocolVersionMismatch(client: 1, service: 2)))
        assertPermanentFailure(await run(.messageTooLarge(bytes: 33_554_432)))
        assertPermanentFailure(await run(.invalidRequest(message: "x")))
    }

    // MARK: - К44 (C-012 §4, строка cancelled)

    func test_k44_cancelledMapsToSuccessWhenQueueInitiated() async {
        let port = FakeTranscriptionServicePort()
        port.forcedError = .cancelled
        let handler = TranscribeJobHandler(port: port)
        let theJob = job()

        let task = Task { await handler.run(theJob, progress: { _ in }) }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .success, "cancelled в отменённом задачей контексте — успех")
    }

    func test_k44_cancelledWithoutQueueInitiationIsPermanentFailure() async {
        let outcome = await run(.cancelled)
        assertPermanentFailure(outcome)
    }

    // MARK: - К45 (C-012 §4, таблица кодов engineFailure)

    func test_k45_engineFailureCodesToJobOutcome() async {
        for code in ["modelMissing", "modelIncompatible", "audioUnreadable",
                     "unsupportedLanguage", "unsupportedRequest", "invalidResult"] {
            assertPermanentFailure(await run(.engineFailure(code: code, message: "x")))
        }
        assertRetry(await run(.engineFailure(code: "outOfMemory", message: "x")), after: 600)
        assertRetry(await run(.engineFailure(code: "runtimeFailure", message: "x")), after: 30)
        assertRetry(await run(.engineFailure(code: "codeFromNewerService", message: "x")), after: 30)
    }

    func test_k45_engineFailureCancelledCodeFollowsSameForkAsK44() async {
        let port = FakeTranscriptionServicePort()
        port.forcedError = .engineFailure(code: "cancelled", message: "движок сам отменил")
        let handler = TranscribeJobHandler(port: port)
        let theJob = job()

        let task = Task { await handler.run(theJob, progress: { _ in }) }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .success, "engineFailure(code: \"cancelled\") — та же развилка, что К44")

        assertPermanentFailure(await run(.engineFailure(code: "cancelled", message: "без отмены")))
    }

    // MARK: - К47 (C-012 §4.1, расписание задержек modelsNotReady)

    func test_k47_retryScheduleThreePointsByAttempts() async {
        let error = TranscriptionServiceError.modelsNotReady(profileId: "ru-default", message: "загрузка")
        assertRetry(await run(error, attempts: 0), after: 300)
        assertRetry(await run(error, attempts: 1), after: 900)
        assertRetry(await run(error, attempts: 7), after: 900)
    }
}
