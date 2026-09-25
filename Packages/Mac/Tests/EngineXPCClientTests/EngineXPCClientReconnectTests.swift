//  EngineXPCClientReconnectTests — план MEE-389: К29 (падение сервиса — все живые задачи
//  получают `serviceCrashed` ровно раз, клиент не повторяет запрос сам), К30 (выгрузка по
//  простою — следующий запрос тем же клиентом переподключается прозрачно), К52
//  (`interruptionHandler` vs `invalidationHandler` — разные обработчики, разный исход).

import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientReconnectTests: XCTestCase {

    private func makeSpec() -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    /// К29: три параллельных запроса, соединение обрывается («сервис упал») — каждый живой
    /// `jobId` получает `serviceCrashed` ровно один раз; после обрыва клиент сам не
    /// повторяет отправку (счётчик транспорта не растёт сверх трёх исходных).
    func test_k29_serviceCrashedAllLiveJobsOnceThenNoAutoRetry() async throws {
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 5_000_000_000   // с большим запасом дольше обрыва
        let fixture = XPCFixture(service: TestEngineXPCService(transcription: engine))
        configureReadyProfile(fixture.modelCatalog)

        let tasks = (0..<3).map { _ in
            Task { try await fixture.client.transcribe(self.makeSpec()) { _ in } }
        }
        try await Task.sleep(nanoseconds: 150_000_000)   // дать всем трём уйти на сервис
        let sendsBeforeCrash = fixture.service.sendCount
        fixture.simulateServiceCrash()

        for task in tasks {
            do {
                _ = try await task.value
                XCTFail("ожидался serviceCrashed")
            } catch TranscriptionServiceError.serviceCrashed {
                // ожидаемо
            }
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.service.sendCount, sendsBeforeCrash, "клиент не повторяет отправку сам")
    }

    /// К30: после обрыва следующий запрос тем же клиентом выполняется успешно — клиент
    /// пересоздаёт соединение (`makeConnection`) на этот же анонимный слушатель прозрачно
    /// для вызывающей стороны.
    func test_k30_reconnectsTransparentlyAfterCrash() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)

        _ = try await fixture.client.transcribe(makeSpec()) { _ in }
        fixture.simulateServiceCrash()
        // Дать обработчику обрыва отработать перед следующим запросом.
        try await Task.sleep(nanoseconds: 100_000_000)

        let transcript = try await fixture.client.transcribe(makeSpec()) { _ in }

        XCTAssertEqual(
            transcript.engine, "fake-transcription", "запрос после обрыва обязан пройти как ни в чём не бывало"
        )
    }

    /// К52: `interruptionHandler` (К29 — «сервис упал», настоящий обрыв) и `invalidationHandler`
    /// (эта задача — соединение стало недействительным БЕЗ краха: сам клиент вызвал
    /// `invalidate()` на СВОЁМ соединении) — два разных обработчика с разным исходом.
    /// `NSXPCConnection` документированно зовёт только `invalidationHandler` на явный
    /// собственный `invalidate()`, не `interruptionHandler` (тот — только на обрыв УДАЛЁННОЙ
    /// стороны); красный этого теста — `serviceCrashed` вместо `serviceUnavailable` доказал
    /// бы, что оба пути перепутаны местами.
    func test_k52_clientSideInvalidationWithoutCrashMapsToServiceUnavailableNotServiceCrashed() async throws {
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 2_000_000_000   // с запасом дольше, чем сама инвалидация
        let fixture = XPCFixture(service: TestEngineXPCService(transcription: engine))
        configureReadyProfile(fixture.modelCatalog)

        let task = Task { try await fixture.client.transcribe(self.makeSpec()) { _ in } }
        try await Task.sleep(nanoseconds: 150_000_000)   // дать запросу дойти до сервиса
        let connection = fixture.client.locked { fixture.client.connection }
        connection?.invalidate()

        do {
            _ = try await task.value
            XCTFail("ожидался serviceUnavailable, не serviceCrashed")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо — invalidationHandler, не interruptionHandler
        }
    }
}
