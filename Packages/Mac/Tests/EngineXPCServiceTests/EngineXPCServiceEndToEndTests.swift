//  EngineXPCServiceEndToEndTests — MEE-438: настоящий `EngineXPCClient` (публичный API,
//  `TranscriptionServicePort`) против настоящей стороны сервиса. Перечень MEE-370 не называет
//  ни одного критерия, целящего `Services/TranscriptionEngineXPC` напрямую (группа Р и все
//  macOS-критерии проверяют `EngineXPCClient` + тестовый двойник сервиса) — эти тесты
//  подтверждают, что реальный продакшн-диспетчер воспроизводит те же исходы, что уже доказаны
//  в MEE-431 на двойнике, ПЛЮС собственно сервисные обязанности (§2.1 нормализация дат перед
//  encode, ping версии сервиса), которых до появления настоящего кода сервиса проверить
//  было нечем.

import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCServiceEndToEndTests: XCTestCase {

    private func makeSpec(profileId: String = "p1") -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: profileId, language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: false
        )
    }

    func test_pingReturnsRealServiceVersionAndMatchingProtocolVersion() async throws {
        let fixture = RealServiceFixture(serviceVersion: "meet-for-me-engine-xpc-test")

        let version = try await fixture.client.ping()

        XCTAssertEqual(version, "meet-for-me-engine-xpc-test")
    }

    func test_transcribeSucceedsThroughRealProductionServiceDispatch() async throws {
        let fixture = RealServiceFixture()
        configureReadyServiceProfile(fixture.modelCatalog)

        let transcript = try await fixture.client.transcribe(makeSpec()) { _ in }

        XCTAssertEqual(transcript.engine, fixture.transcription.engineId)
        XCTAssertFalse(transcript.segments.isEmpty)
    }

    func test_embedSucceedsThroughRealProductionServiceDispatch() async throws {
        let fixture = RealServiceFixture()
        configureReadyServiceProfile(fixture.modelCatalog, embeddingModelId: "emb-1")

        let vector = try await fixture.client.embed(
            recordingId: UUID(), startMs: 0, endMs: 1_000, profileId: "p1"
        )

        XCTAssertEqual(vector.count, fixture.embedding.dimension)
    }

    /// §2.1: `EngineWire.normalizingDates(_:)` — последний шаг СЕРВИСА перед `encode`, для
    /// исходящего `EngineReply.transcript`. Движок отдаёт `createdAt` с долей секунды МЕЛЬЧЕ
    /// миллисекунды — если бы сервис не нормализовал его сам (полагаясь на то, что вход уже
    /// выровнен), это значение прошло бы насквозь как есть.
    func test_transcriptCreatedAtIsRoundedToMillisecondByRealService() async throws {
        let fixture = RealServiceFixture()
        configureReadyServiceProfile(fixture.modelCatalog)
        let unrounded = Date(timeIntervalSince1970: 1_700_000_000.123_449)
        fixture.transcription.forcedResult = {
            try Transcript(
                recordingId: UUID(), language: "ru", engine: fixture.transcription.engineId,
                modelVersion: "v1", createdAt: unrounded,
                segments: [try Transcript.Segment(
                    startMs: 0, endMs: 100, channel: .mic, speakerCluster: nil,
                    text: "x", textOriginal: nil, textConfidence: 0.5, words: []
                )],
                speakers: []
            )
        }

        let transcript = try await fixture.client.transcribe(makeSpec()) { _ in }

        let expectedMs = (unrounded.timeIntervalSince1970 * 1_000).rounded()
        let actualMs = (transcript.createdAt.timeIntervalSince1970 * 1_000).rounded()
        XCTAssertEqual(actualMs, expectedMs)
        XCTAssertNotEqual(transcript.createdAt, unrounded, "сырое значение не должно было дойти как есть")
    }

    /// Возврат РП по MEE-438 (11:50 UTC): обратный канал прогресса до сих пор проверялся
    /// только `rawServiceProxy` (`didReceiveProgress` напрямую, без настоящего клиентского
    /// приёмника) — здесь тот же прогресс идёт ЦЕЛИКОМ настоящим путём: сервис
    /// (`EngineXPCRequestHandler.pushProgress`) → настоящий `NSXPCConnection` → настоящий
    /// `EngineXPCClient.ProgressReceiver` → замыкание прогресса `transcribe(_:progress:)`.
    ///
    /// РАСКРЫТИЕ по возврату РП (12:15 UTC): этот тест доказывает, что доставка прогресса через
    /// настоящий клиентский путь вообще работает end-to-end, НЕ саму обязанность инв. 3 «сервис
    /// не шлёт прогресс после финального ответа» — `EngineXPCClient.deliverProgress`
    /// (`EngineXPCClient+Transport.swift`, К40iii) молча отбрасывает кадр прогресса по
    /// НЕИЗВЕСТНОМУ/уже снятому `jobId` независимо от того, продолжает ли СЕРВИС (ошибочно)
    /// слать что-то после ответа — то есть этот тест прошёл бы одинаково и при настоящем
    /// нарушении инв. 3 сервисом. Саму обязанность сервиса доказывает
    /// `test_serviceDoesNotPushProgressAfterSendingFinalReply` ниже, минуя эту фильтрацию
    /// клиента (`rawServiceProxy`, видит кадры сервиса как есть).
    func test_progressFlowsFromRealServiceThroughRealClient() async throws {
        let fixture = RealServiceFixture()
        configureReadyServiceProfile(fixture.modelCatalog)
        fixture.transcription.progressScript = [
            .started(stage: .asr), .advanced(stage: .asr, fraction: 0.5), .finished(stage: .asr)
        ]
        let collector = TranscriptionProgressCollector()

        _ = try await fixture.client.transcribe(makeSpec()) { progress in collector.append(progress) }

        XCTAssertEqual(collector.all.count, 3, "все три события сценария обязаны дойти")
        XCTAssertEqual(collector.all.map(\.stage), [EngineStage.asr, .asr, .asr].map(\.rawValue))
    }

    /// Инв. 3 (§2, C-012 v10), собственная обязанность СЕРВИСА, а не наблюдаемый исход на
    /// клиенте: через `rawServiceProxy` — кадры прогресса приходят как есть, без фильтрации
    /// `EngineXPCClient` по `jobId` (см. раскрытие теста выше), так что нарушение здесь нельзя
    /// замаскировать поведением клиента. Общий порядок доказывается наблюдаемо: каждый кадр
    /// прогресса помечается временем ДО отправки реплая (сервис не может физически звать
    /// `pushProgress` из `start` ПОСЛЕ того, как тот же `Task` уже вызвал `finish` — единственная
    /// точка вызова `pushProgress` лексически внутри замыкания `operation`, до `wrap`/`finish`),
    /// а после получения финального ответа новых кадров прогресса не приходит вовсе — тот же
    /// приём, что уже стоял в клиентском тесте, но здесь наблюдение идёт по кадрам самого
    /// сервиса, а не по тому, что клиент решил из них показать.
    func test_serviceDoesNotPushProgressAfterSendingFinalReply() async {
        await withDeadline {
            let fixture = RealServiceFixture()
            fixture.transcription.progressScript = [
                .started(stage: .asr), .advanced(stage: .asr, fraction: 0.5), .finished(stage: .asr)
            ]
            let timeline = OrderedEventTimeline()
            let (proxy, connection) = fixture.rawServiceProxy(onProgress: { _ in timeline.recordProgress() })
            defer { connection.invalidate() }
            let audio = try? ServiceFixtures.audioRef()
            guard let audio,
                  let request = try? TranscriptionRequest(
                    audio: [audio], language: nil, wantWordTimestamps: false,
                    asrModel: ServiceFixtures.modelBundle(role: .asr), vadModel: nil
                  ),
                  let requestData = try? EngineWire.encode(
                    EngineRequest.transcribe(EngineJobId(rawValue: UUID()), request)
                  )
            else { return XCTFail("не удалось построить запрос") }

            let (data, error) = await send(proxy, requestData)
            timeline.recordReply()

            XCTAssertNil(error)
            XCTAssertNotNil(data)
            // Даём событийному циклу шанс — если бы сервис (ошибочно) продолжал слать прогресс
            // после финального ответа, лишний кадр успел бы дойти за этот срок и попасть в
            // `progressAfterReply` ниже.
            try? await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertGreaterThan(timeline.progressBeforeReply, 0, "сценарий обязан был прислать прогресс")
            XCTAssertEqual(timeline.progressAfterReply, 0, "прогресс не должен приходить после финального ответа")
        }
    }
}

/// Тот же приём, что `DeadlineOutcome`/`TranscriptionProgressCollector` (`TestSupport.swift`) —
/// потокобезопасный счётчик «сколько кадров прогресса пришло до и после финального ответа».
private final class OrderedEventTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var replyReceived = false
    private var progressCountBeforeReply = 0
    private var progressCountAfterReply = 0

    func recordProgress() {
        lock.lock(); defer { lock.unlock() }
        if replyReceived { progressCountAfterReply += 1 } else { progressCountBeforeReply += 1 }
    }

    func recordReply() {
        lock.lock(); replyReceived = true; lock.unlock()
    }

    var progressBeforeReply: Int { lock.lock(); defer { lock.unlock() }; return progressCountBeforeReply }
    var progressAfterReply: Int { lock.lock(); defer { lock.unlock() }; return progressCountAfterReply }
}
