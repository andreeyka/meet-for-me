//  EngineXPCClientCancellationTests — план MEE-389: К27 (гонка отмены с обычным
//  завершением), К28 (`Task.cancel()` шлёт кадр `cancel` и бросает `.cancelled`, не
//  дожидаясь ответа).

import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientCancellationTests: XCTestCase {

    private func makeSpec() -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    /// К28: отмена `Task` во время ожидания — клиент бросает `.cancelled` без ожидания
    /// финального ответа; кадр `cancel` уходит (счётчик отправок сервиса растёт минимум на
    /// два — сам `transcribe` и `cancel`).
    func test_k28_taskCancelSendsCancelFrameAndThrowsImmediately() async throws {
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 2_000_000_000   // 2с — с запасом дольше отмены
        let fixture = XPCFixture(service: TestEngineXPCService(transcription: engine))
        configureReadyProfile(fixture.modelCatalog)

        let task = Task {
            try await fixture.client.transcribe(self.makeSpec()) { _ in }
        }
        try await Task.sleep(nanoseconds: 100_000_000)   // дать transcribe уйти на сервис
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("ожидался TranscriptionServiceError.cancelled")
        } catch TranscriptionServiceError.cancelled {
            // ожидаемо
        }

        // Кадр cancel действительно ушёл на сервис — ждём короткое время, пока он долетит.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThanOrEqual(fixture.service.sendCount, 2, "transcribe и cancel — минимум два кадра")
    }

    /// К27: гонка — обычное завершение раньше, чем клиент успел бы отменить, — результат
    /// нормальный, не отказ. Здесь: движок мгновенный, `Task.cancel()` зовём ПОСЛЕ await
    /// (то есть никогда, пока задача жива) — просто проверяем, что штатный путь без отмены
    /// доходит нормальным результатом.
    func test_k27_normalCompletionWithoutCancellationSucceeds() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)

        let transcript = try await fixture.client.transcribe(makeSpec()) { _ in }

        XCTAssertEqual(transcript.engine, "fake-transcription")
    }

    /// К27 (второй вход): отменённая задача, чей финальный ответ (`EngineReply.cancelled`)
    /// приходит уже ПОСЛЕ того, как клиент сам резолвил `.cancelled` по К28, — второй резолв
    /// продолжения обязан быть no-op, не крашем и не повторным исходом наружу.
    func test_k27_lateArrivingCancelledReplyIsIgnoredAfterClientAlreadyResolved() async throws {
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 300_000_000
        let fixture = XPCFixture(service: TestEngineXPCService(transcription: engine))
        configureReadyProfile(fixture.modelCatalog)

        let task = Task {
            try await fixture.client.transcribe(self.makeSpec()) { _ in }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("ожидался cancelled")
        } catch TranscriptionServiceError.cancelled {
            // ожидаемо — К28
        }

        // Дать реальному EngineReply.cancelled(jobId) время дойти после уже случившегося
        // резолва — падения/повторного исхода быть не должно (проверяется самим фактом,
        // что тест доходит досюда и завершается).
        try await Task.sleep(nanoseconds: 500_000_000)
    }
}
