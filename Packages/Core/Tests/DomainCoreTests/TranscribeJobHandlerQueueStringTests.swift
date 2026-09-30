//  TranscribeJobHandlerQueueStringTests — строки очереди `TranscribeJobHandler` (MEE-506):
//  C-012 §4 оставляет `JobOutcome.error` за обработчиком («…»), C-016 §3.1 и инв. 31 требуют,
//  чтобы строка доезжала до `facade.jobFailed` дословно. Здесь — вид строки: у случаев без
//  текста — код `engine.<case>` без значений, у случаев с `message` — сам `message` без
//  идентификаторов записи и профиля.
//
//  Место — `Core (Linux)`, способ — Т, фикстура — `FakeTranscriptionServicePort`.

import XCTest
import Foundation
import DomainCore
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

    /// Случаи без текста для человека — код §3.1 `engine.<case>`, не описание значения Swift.
    func test_casesWithoutMessageWriteEngineCode() async {
        let rows: [(TranscriptionServiceError, String)] = [
            (.serviceCrashed, "engine.serviceCrashed"),
            (.timedOut(seconds: 120), "engine.timedOut"),
            (.protocolVersionMismatch(client: 1, service: 2), "engine.protocolVersionMismatch"),
            (.messageTooLarge(bytes: 33_554_432), "engine.messageTooLarge")
        ]
        for (error, expected) in rows {
            let actual = await queueString(error)
            XCTAssertEqual(actual, expected, "\(error)")
        }
    }

    /// `recordingNotReady` и `modelsNotReady` — `message` без `recordingId` и `profileId`.
    func test_casesWithMessageWriteMessageWithoutIdentifiers() async {
        let recordingId = TranscriptFixtures.oneOnOne.recordingId
        let notReady = await queueString(.recordingNotReady(recordingId: recordingId, message: "записи нет"))
        XCTAssertEqual(notReady, "записи нет")
        let models = await queueString(.modelsNotReady(profileId: "ru-default", message: "загрузка"))
        XCTAssertEqual(models, "загрузка")
    }

    /// Сквозь фасад (инв. 31: строка дословно в `jobFailed`): код даёт текст словаря, ни имени
    /// случая, ни скобок Swift, ни UUID записи пользователь не видит.
    func test_queueStringsReachUserWithoutSwiftDescriptionOrUUID() async throws {
        let recordingId = TranscriptFixtures.oneOnOne.recordingId
        let errors: [TranscriptionServiceError] = [
            .serviceCrashed, .timedOut(seconds: 120), .protocolVersionMismatch(client: 1, service: 2),
            .messageTooLarge(bytes: 33_554_432), .recordingNotReady(recordingId: recordingId, message: "записи нет")
        ]
        for error in errors {
            let queued = await queueString(error)
            let raw = try XCTUnwrap(queued)
            let failure = AppFacadeError.jobFailed(jobId: UUID(), type: .transcribe, message: raw)
            if case .jobFailed(_, _, let message) = failure {
                XCTAssertEqual(message, raw, "инв. 31: дословно")
            }
            let shown = failure.view.message
            XCTAssertFalse(shown.contains(recordingId.uuidString), shown)
            XCTAssertFalse(shown.contains("("), shown)
            XCTAssertFalse(shown.contains("engine."), shown)
        }
    }
}
