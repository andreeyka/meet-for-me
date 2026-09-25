//  EngineXPCClientTimingTests — план MEE-389: К22 (уникальный `EngineJobId` на каждый
//  запрос), К23 (запоздалый прогресс после финального ответа не публикуется), К38
//  (таймауты 120с/10с на инжектируемых часах, сброс прогрессом).

import XCTest
import DomainCore
import DomainTestKit
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientTimingTests: XCTestCase {

    private func makeSpec() -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    // MARK: - К22: уникальный jobId на каждый запрос, один транспорт

    func test_k22_eachRequestGetsUniqueJobIdOnSameConnection() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)

        _ = try await fixture.client.transcribe(makeSpec()) { _ in }
        _ = try await fixture.client.transcribe(makeSpec()) { _ in }
        _ = try await fixture.client.transcribe(makeSpec()) { _ in }

        let jobIds = Set(fixture.service.receivedJobIds)
        XCTAssertEqual(jobIds.count, 3, "три запроса — три различных jobId")
    }

    // MARK: - К23: запоздалый прогресс после финального ответа не публикуется

    func test_k23_lateProgressAfterFinalReplyNotPublished() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)
        var receivedCount = 0

        _ = try await fixture.client.transcribe(makeSpec()) { _ in receivedCount += 1 }
        let jobId = try XCTUnwrap(fixture.service.receivedJobIds.last)
        let countAfterCompletion = receivedCount

        // Ответ на этот jobId уже ушёл — кадр прогресса теперь заведомо запоздалый.
        fixture.service.pushRawProgress(jobId: jobId, progress: .advanced(stage: .asr, fraction: 0.5))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            receivedCount, countAfterCompletion, "запоздалый прогресс не должен был дойти до вызывающей стороны"
        )
    }

    // MARK: - К38: таймауты на инжектируемых часах

    func test_k38_timesOutAfter120SecondsOfNoActivity() async throws {
        let clock = ManualClock()
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 60_000_000_000   // дольше, чем тест реально будет ждать
        let fixture = XPCFixture(service: TestEngineXPCService(transcription: engine), clock: { clock.now() })
        configureReadyProfile(fixture.modelCatalog)
        _ = try await fixture.client.ping()   // рукопожатие — своя, уже завершённая, отправка

        let task = Task { try await fixture.client.transcribe(self.makeSpec()) { _ in } }
        try await Task.sleep(nanoseconds: 150_000_000)   // дать запросу дойти до сервиса
        clock.advance(by: 121)

        do {
            _ = try await task.value
            XCTFail("ожидался timedOut(120)")
        } catch TranscriptionServiceError.timedOut(let seconds) {
            XCTAssertEqual(seconds, 120)
        }
    }

    func test_k38_pingTimesOutAfter10Seconds() async throws {
        let clock = ManualClock()
        let service = TestEngineXPCService()
        service.swallowPing = true
        let fixture = XPCFixture(service: service, clock: { clock.now() })

        let task = Task { try await fixture.client.ping() }
        try await Task.sleep(nanoseconds: 150_000_000)
        clock.advance(by: 11)

        do {
            _ = try await task.value
            XCTFail("ожидался timedOut(10)")
        } catch TranscriptionServiceError.timedOut(let seconds) {
            XCTAssertEqual(seconds, 10)
        }
    }

    /// К38 (сброс): кадр прогресса посреди ожидания сдвигает момент последней активности —
    /// таймаут 120с не наступает раньше времени, отсчитанного ОТ ЭТОГО кадра. Наблюдаемо
    /// через инвертированное ожидание: задача не обязана завершиться на отметке «180с от
    /// старта, 90с от прогресса» — только на «121с от прогресса».
    func test_k38_progressResetsTimeoutCountdown() async throws {
        let clock = ManualClock()
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 60_000_000_000
        let fixture = XPCFixture(service: TestEngineXPCService(transcription: engine), clock: { clock.now() })
        configureReadyProfile(fixture.modelCatalog)
        _ = try await fixture.client.ping()

        let notYetSettled = expectation(description: "не завершилось раньше срока, отсчитанного от прогресса")
        notYetSettled.isInverted = true
        let task = Task<Void, Never> {
            _ = try? await fixture.client.transcribe(self.makeSpec()) { _ in }
            notYetSettled.fulfill()
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let jobId = try XCTUnwrap(fixture.service.receivedJobIds.last)

        clock.advance(by: 90)
        fixture.service.pushRawProgress(jobId: jobId, progress: .advanced(stage: .asr, fraction: 0.5))
        try await Task.sleep(nanoseconds: 100_000_000)   // дать сторожу увидеть сброс на 90с
        clock.advance(by: 90)   // 90 + 90 = 180 от старта, но только 90 от прогресса — не таймаут
        await fulfillment(of: [notYetSettled], timeout: 0.3)

        clock.advance(by: 31)   // теперь 121с от последнего прогресса — таймаут наступает
        _ = await task.value
    }
}
