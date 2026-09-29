//  TranscodeJobHandlerTests — обработчик-пустышка `.transcode` (C-013 v16, IR-151 MEE-485):
//  `run` возвращает `.success`, не обращаясь ни к одному порту и репозиторию; очередь с
//  четырьмя обработчиками проводит `transcode` до `succeeded`, цепочка доходит до `attribute`.
//
//  Место — `Core (Linux)`, способ — Т.

import XCTest
import Foundation
import DomainCore
import DomainTestKit

final class TranscodeJobHandlerTests: XCTestCase {

    func test_typeIsTranscode() {
        XCTAssertEqual(TranscodeJobHandler().type, .transcode)
    }

    /// У `TranscodeJobHandler` нет зависимостей (`init()` без параметров), а рядом лежат
    /// репозитории и порт с журналом вызовов: после `run` журнал пуст.
    func test_runReturnsSuccessWithoutTouchingPortsOrRepositories() async throws {
        let log = PortCallLog()
        let transcripts = InMemoryTranscriptRepository(log: log)
        let port = FakeTranscriptionServicePort()
        let recordingId = UUID()

        let outcome = await TranscodeJobHandler().run(
            Self.job(payload: .transcode(recordingId: recordingId)), progress: { _ in }
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(port.transcribeCallCount, 0)
        let headers = try await transcripts.headers(recordingId: recordingId)
        XCTAssertEqual(headers.count, 0, "в хранилище ничего не появилось")
    }

    /// Стенд очереди: четыре зарегистрированных типа, цепочка `transcode → transcribe →
    /// diarize → attribute` проходит до `succeeded` на каждом звене.
    func test_queueWithFourHandlersRunsChainThroughAttribute() async throws {
        let rig = JobQueueTestRig()
        try await rig.queue.register(handler: TranscodeJobHandler())
        let transcribe = FakeJobHandler(type: .transcribe)
        let attribute = FakeJobHandler(type: .attribute)
        try await rig.queue.register(handler: transcribe)
        try await rig.queue.register(handler: DiarizeJobHandler())
        try await rig.queue.register(handler: attribute)

        let recordingId = UUID()
        let payloads: [JobPayload] = [
            .transcode(recordingId: recordingId),
            .transcribe(recordingId: recordingId, profileId: "ru-default", language: nil),
            .diarize(recordingId: recordingId, profileId: "ru-default"),
            .attribute(transcriptId: UUID(), meetingId: nil)
        ]
        var ids: [UUID] = []
        for payload in payloads {
            ids.append(try await rig.queue.submit(makeSubmission(payload: payload)))
        }

        await rig.queue.start()
        await rig.queue.waitUntilIdle()

        for id in ids {
            let job = try await rig.repository.job(id: id)
            XCTAssertEqual(job?.status, .succeeded, "\(String(describing: job?.type))")
        }
        XCTAssertEqual(transcribe.runCallCount, 1)
        XCTAssertEqual(attribute.runCallCount, 1, "цепочка дошла до attribute")
    }

    private static func job(payload: JobPayload) -> Job {
        Job(
            id: UUID(), type: .transcode, payload: payload,
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
