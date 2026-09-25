//  EngineXPCClientTimingTests — план MEE-389: К22 (уникальный `EngineJobId` на каждый
//  запрос), К23 (запоздалый прогресс после финального ответа не публикуется), К32
//  (отображение стадии/доли прогресса), К38 (таймауты 120с/10с на инжектируемых часах,
//  сброс прогрессом), К40(ii-iii) (испорченный/чужой кадр прогресса молча отброшен).

import Foundation
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

    /// Счётчик, защищённый блокировкой — замыкание прогресса `@Sendable`, обычный `var` тест
    /// мутировать из него не может.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func test_k23_lateProgressAfterFinalReplyNotPublished() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)
        let receivedCount = Counter()

        _ = try await fixture.client.transcribe(makeSpec()) { _ in receivedCount.increment() }
        let jobId = try XCTUnwrap(fixture.service.receivedJobIds.last)
        let countAfterCompletion = receivedCount.current

        // Ответ на этот jobId уже ушёл — кадр прогресса теперь заведомо запоздалый.
        fixture.service.pushRawProgress(jobId: jobId, progress: .advanced(stage: .asr, fraction: 0.5))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            receivedCount.current, countAfterCompletion, "запоздалый прогресс не должен был дойти до вызывающей стороны"
        )
    }

    // MARK: - К32 (отображение): стадия/доля прогресса переданы верно потребителю

    /// Собиратель значений прогресса — `@Sendable`-замыканию нельзя мутировать обычный `var`
    /// (тот же приём, что `Counter` выше).
    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [TranscriptionProgress] = []
        func append(_ item: TranscriptionProgress) { lock.lock(); items.append(item); lock.unlock() }
        var all: [TranscriptionProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// К32 (отображение): реальный движок скриптован тремя стадиями `EngineProgress`, идущими
    /// через настоящий провод (`EngineWire`/`NSXPCConnection`) — клиент обязан отдать
    /// потребителю ровно `stage.rawValue` и `0` для `.started`/`.finished`, реальную долю
    /// только для `.advanced`.
    func test_k32_progressStageAndFractionMappedThroughRealTransport() async throws {
        let engine = FakeTranscriptionEngine()
        engine.progressScript = [
            .started(stage: .asr),
            .advanced(stage: .asr, fraction: 0.5),
            .finished(stage: .asr)
        ]
        let fixture = XPCFixture(service: TestEngineXPCService(transcription: engine))
        configureReadyProfile(fixture.modelCatalog)
        let collector = ProgressCollector()

        _ = try await fixture.client.transcribe(makeSpec()) { collector.append($0) }

        let received = collector.all
        XCTAssertEqual(received.map(\.stage), ["asr", "asr", "asr"])
        XCTAssertEqual(received.map(\.fraction), [0, 0.5, 0])
    }

    // MARK: - К40(ii): кадр прогресса, испорченный на проводе — молча отброшен

    /// Возврат РП по MEE-431 (10:27 UTC): не только «клиент не падает и работает дальше» —
    /// сборщик прогресса на самой ЖИВОЙ задаче, до которой испорченный/чужой кадр не должен
    /// был дойти, и настоящий кадр ТОЙ ЖЕ задачи сразу следом, доказывающий, что порченый
    /// кадр не сбил слежение за настоящей задачей.
    ///
    /// К40(ii): кадр прогресса, доля которого вне представимого диапазона (та же порча, что
    /// `EngineWireMalformedFieldTests.test_k40i_corruptedProgressFrameFailsToDecode` на
    /// Core (Linux) — `PlistSurgery`, реальный `EngineWire.decode` бросает на decode).
    func test_k40ii_progressFrameWithUnrepresentableFractionSilentlyDropped() async throws {
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 2_000_000_000   // с запасом дольше, чем тест ждёт
        let fixture = XPCFixture(service: TestEngineXPCService(transcription: engine))
        configureReadyProfile(fixture.modelCatalog)
        let collector = ProgressCollector()

        let task = Task { try await fixture.client.transcribe(self.makeSpec()) { collector.append($0) } }
        try await Task.sleep(nanoseconds: 150_000_000)   // дать transcribe дойти до сервиса
        let jobId = try XCTUnwrap(fixture.service.receivedJobIds.last)

        let corrupted = try PlistSurgery.data(
            for: EngineProgressMessage(jobId: jobId, progress: .advanced(stage: .asr, fraction: 0.5)),
            replacing: "<real>0.5</real>", with: "<real>1e400</real>"
        )
        fixture.service.pushRawProgressData(corrupted)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(collector.all.count, 0, "испорченный кадр не должен был долететь до потребителя")

        fixture.service.pushRawProgress(jobId: jobId, progress: .advanced(stage: .asr, fraction: 0.3))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            collector.all.map(\.fraction), [0.3], "настоящий прогресс той же задачи обязан дойти как обычно"
        )
        _ = try await task.value
    }

    // MARK: - К40(iii): кадр прогресса для чужого jobId — молча отброшен

    /// К40(iii), вторая половина: `jobId`, которого клиент не знает ВООБЩЕ (не «уже
    /// завершённый», как К23, а никогда не существовавший) — кадр отбрасывается тем же
    /// путём (`guard let job else { return }`); та же схема, что К40(ii) — живая задача,
    /// чужой кадр не доходит, настоящий следом доходит как обычно.
    func test_k40iii_progressForNeverKnownForeignJobIdSilentlyDropped() async throws {
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 2_000_000_000
        let fixture = XPCFixture(service: TestEngineXPCService(transcription: engine))
        configureReadyProfile(fixture.modelCatalog)
        let collector = ProgressCollector()

        let task = Task { try await fixture.client.transcribe(self.makeSpec()) { collector.append($0) } }
        try await Task.sleep(nanoseconds: 150_000_000)
        let jobId = try XCTUnwrap(fixture.service.receivedJobIds.last)

        let foreignJobId = EngineJobId(rawValue: UUID())
        fixture.service.pushRawProgress(jobId: foreignJobId, progress: .advanced(stage: .asr, fraction: 0.9))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(collector.all.count, 0, "чужой кадр не должен был долететь до потребителя")

        fixture.service.pushRawProgress(jobId: jobId, progress: .advanced(stage: .asr, fraction: 0.4))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            collector.all.map(\.fraction), [0.4], "настоящий прогресс живой задачи обязан дойти как обычно"
        )
        _ = try await task.value
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
