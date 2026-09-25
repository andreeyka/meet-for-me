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
    /// финального ответа; кадр `.cancel(jobId)` уходит на сервис для ТОГО ЖЕ jobId, что и
    /// сам отменённый `transcribe`.
    ///
    /// Возврат РП по MEE-431 (09:40 UTC): прежняя проверка (`sendCount >= 2`) не доказывала
    /// ничего конкретного про сам кадр `cancel` — той же отметки достигает рукопожатие
    /// (`ping`, sendCount 1) плюс исходный `transcribe` (sendCount 2), даже если `cancel`
    /// вообще не долетел. Проверка ниже — что и `.transcribe(jobId, …)`, и его `.cancel(jobId)`
    /// оба разобраны сервисом с ОДНИМ И ТЕМ ЖЕ jobId (`receivedJobIds` несёт его дважды).
    func test_k28_taskCancelSendsCancelFrameAndThrowsImmediately() async throws {
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 2_000_000_000   // 2с — с запасом дольше отмены
        let fixture = XPCFixture(service: TestEngineXPCService(transcription: engine))
        configureReadyProfile(fixture.modelCatalog)

        let task = Task {
            try await fixture.client.transcribe(self.makeSpec()) { _ in }
        }
        try await Task.sleep(nanoseconds: 100_000_000)   // дать transcribe уйти на сервис
        let jobId = try XCTUnwrap(fixture.service.receivedJobIds.last, "transcribe обязан был дойти до сервиса")
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("ожидался TranscriptionServiceError.cancelled")
        } catch TranscriptionServiceError.cancelled {
            // ожидаемо
        }

        // Кадр cancel действительно ушёл на сервис — ждём короткое время, пока он долетит.
        try await Task.sleep(nanoseconds: 200_000_000)
        let occurrences = fixture.service.receivedJobIds.filter { $0 == jobId }.count
        XCTAssertEqual(occurrences, 2, "тот же jobId обязан прийти дважды: сам transcribe и его cancel")
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

    /// Инв. 12, возврат РП по MEE-431 (09:40 UTC): `Task`, отменённый ДО того, как его тело
    /// вообще начало выполняться — `withTaskCancellationHandler` зовёт `onCancel` немедленно
    /// (Swift-документированное поведение для уже отменённой задачи), КОНКУРЕНТНО с
    /// `operation`, и раньше без проверки после регистрации `onCancel` находил бы `jobs[jobId]`
    /// ещё пустым (запрос не зарегистрирован) — отмена терялась бы молча, а запрос (в этом
    /// случае — сам внутренний рукопожатный `ping`, до которого `transcribe` не успевает
    /// дойти) всё равно ушёл бы на транспорт. `task.cancel()` без единого `await` между
    /// созданием `Task` и вызовом — на этом рантайме гарантирует отмену раньше первого
    /// исполнения тела (тот же приём, которым тесты этого файла уже полагаются на порядок
    /// планировщика через `Task.sleep`).
    func test_inv12_taskCancelledBeforeBodyRunsNeverReachesTransport() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)

        let task = Task {
            try await fixture.client.transcribe(self.makeSpec()) { _ in }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("ожидался TranscriptionServiceError.cancelled")
        } catch TranscriptionServiceError.cancelled {
            // ожидаемо
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            fixture.service.sendCount, 0,
            "отменённая до регистрации задача не должна была дойти до транспорта вовсе"
        )
    }
}
