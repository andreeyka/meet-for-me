//  EngineXPCClientErrorMappingTests — план MEE-389: К31 (мисматч версии протокола на любом
//  методе), К32 (отображение — часть, не зависящая от формата будущего сервиса MEE-438),
//  К33 (нераспознанный код транспорта), К35 (malformed reply — оба пусты/оба заданы/чужой
//  jobId/не тот род), К36 (испорченные байты ответа vs. `.failed(invalidResult)` в
//  разобранном ответе), К37 (код `engineFailure` — имя случая дословно; незапрошенная
//  отмена), К39 (разобранный кадр, не подходящий ни одной строке §3.2), К50 (единственные
//  два пути к `invalidRequest`, не третий через `NSCocoaErrorDomain`), К51 (четыре вектора
//  `NSCocoaErrorDomain` настоящего `NSXPCConnection`).

import Foundation
import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientErrorMappingTests: XCTestCase {

    private func makeSpec() -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    private func readyFixture(embeddingModelId: String? = nil) async throws -> XPCFixture {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog, embeddingModelId: embeddingModelId)
        _ = try await fixture.client.ping()   // рукопожатие отдельно от проверяемого вызова
        return fixture
    }

    // MARK: - К31: код 1 на любом методе, не только ping

    func test_k31_protocolVersionMismatchOnEmbedBothKeysPresent() async throws {
        let fixture = try await readyFixture(embeddingModelId: "emb-1")
        fixture.service.forcedTransportFault = (
            code: EngineTransportFault.protocolVersionMismatch.rawValue,
            userInfo: [
                EngineTransportFault.clientProtocolVersionKey: 9,
                EngineTransportFault.serviceProtocolVersionKey: 7
            ]
        )

        do {
            _ = try await fixture.client.embed(recordingId: UUID(), startMs: 0, endMs: 1000, profileId: "p1")
            XCTFail("ожидался protocolVersionMismatch")
        } catch TranscriptionServiceError.protocolVersionMismatch(let client, let service) {
            XCTAssertEqual(client, 9)
            XCTAssertEqual(service, 7)
        }
    }

    func test_k31_protocolVersionMismatchMissingKeysGiveMinusOne() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedTransportFault = (
            code: EngineTransportFault.protocolVersionMismatch.rawValue, userInfo: [:]
        )

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался protocolVersionMismatch")
        } catch TranscriptionServiceError.protocolVersionMismatch(let client, let service) {
            XCTAssertEqual(client, -1)
            XCTAssertEqual(service, -1)
        }
    }

    // MARK: - К32 (отображение): invalidRequest(message:) — текст передан дословно, фолбэк без текста

    /// Возврат РП по MEE-431 (09:40 UTC), раскрытие отклонения от плана MEE-389: план
    /// (`test_k32_invalidRequestFourVectorsDisplay`) хочет четыре КОНКРЕТНЫХ текста
    /// («invariant: C-003…»/«decoding: …»), которые производит СЕРВИС при разборе байтов,
    /// нарушающих инварианты `Transcript`. Настоящий сервис (`Services/TranscriptionEngineXPC`)
    /// не реализован — это отдельная задача MEE-438 (решение РП тем же комментарием), и
    /// придумывать здесь её будущий формат текста означало бы тестировать предположение о
    /// MEE-438, а не код этого PR. Что ДЕЙСТВИТЕЛЬНО принадлежит `EngineXPCClient` (и
    /// проверяется here) — сам механизм: `invalidRequest(message:)` передаёт текст сервиса
    /// ДОСЛОВНО, каким бы он ни был, и подставляет свой текст, когда сервис его не даёт.
    func test_k32_invalidRequestMessagePassedThroughVerbatim() async throws {
        let fixture = try await readyFixture()
        let sampleServiceText = "invariant: C-003.Transcript.Word инв. 7, confidence: уверенность вне 0...1: 1.0000001"
        fixture.service.forcedTransportFault = (
            code: EngineTransportFault.invalidRequest.rawValue,
            userInfo: [NSLocalizedDescriptionKey: sampleServiceText]
        )

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался invalidRequest")
        } catch TranscriptionServiceError.invalidRequest(let message) {
            XCTAssertEqual(message, sampleServiceText, "текст сервиса обязан дойти без изменений")
        }
    }

    /// К32 (отображение), пятый вход плана: код 3 без текста вовсе.
    func test_k32_invalidRequestWithoutDescriptionFallsBackToDefaultMessage() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedTransportFault = (code: EngineTransportFault.invalidRequest.rawValue, userInfo: [:])

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался invalidRequest")
        } catch TranscriptionServiceError.invalidRequest(let message) {
            XCTAssertEqual(message, "описание отсутствует")
        }
    }

    // MARK: - К33: код 4 (сервис новее клиента) — вне диапазона

    func test_k33_unrecognizedTransportCodeMapsToInvalidRequest() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedTransportFault = (code: 4, userInfo: [:])

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался invalidRequest")
        } catch TranscriptionServiceError.invalidRequest(let message) {
            XCTAssertTrue(message.contains("4"), "сообщение обязано называть код: \(message)")
        }
    }

    // MARK: - К35: нарушение протокола ответа

    func test_k35_bothDataAndErrorNilIsMalformed() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (data: nil, error: nil)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    func test_k35_bothDataAndErrorSetIsMalformed() async throws {
        let fixture = try await readyFixture()
        let data = try EngineWire.encode(EngineReply.pong(serviceVersion: "x", protocolVersion: 1))
        let error = NSError(domain: "SomeDomain", code: 1)
        fixture.service.forcedRawResponse = (data: data, error: error)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    func test_k35_foreignJobIdIsMalformed() async throws {
        let fixture = try await readyFixture()
        let foreignReply = try EngineWire.encode(EngineReply.cancelled(EngineJobId(rawValue: UUID())))
        fixture.service.forcedRawResponse = (data: foreignReply, error: nil)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    func test_k35_wrongReplyKindIsMalformed() async throws {
        let fixture = try await readyFixture()
        let diarizationResult = try DiarizationResult(turns: [], speakers: [], modelVersion: "v")
        fixture.service.forcedReplyOverride = { jobId in .diarization(jobId, diarizationResult) }

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    // MARK: - К36: испорченные байты vs. разобранный `.failed(invalidResult)`

    func test_k36_corruptedReplyBytesGivesServiceUnavailable() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (data: Data([0xFF, 0x00, 0x01, 0x02]), error: nil)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable(let message) {
            XCTAssertTrue(message.contains("не разобран"), message)
        }
    }

    /// Возврат РП по MEE-431 (09:40 UTC): вход этого теста — `.failed(jobId, .invalidResult)`,
    /// то есть сервис САМ заметил и заявил отказ. Это форма К37 (случай `EngineError`
    /// дословно в код), а не К36(ii) — тот ниже, на настоящем декодировании.
    func test_k37_failedInvalidResultReplyMapsToEngineFailure() async throws {
        let fixture = try await readyFixture()
        let validationError = DomainValidationError(
            contract: "C-003", type: "Transcript", invariant: 1, path: "segments", message: "тест"
        )
        fixture.service.forcedReplyOverride = { jobId in .failed(jobId, .invalidResult(validationError)) }

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался engineFailure")
        } catch TranscriptionServiceError.engineFailure(let code, _) {
            XCTAssertEqual(code, "invalidResult")
        }
    }

    /// К36(ii): байты дошли целыми и разобраны штатно (не через `forcedRawResponse`/
    /// `forcedReplyOverride`, а настоящим `EngineWire.decode`) — невалиден вложенный
    /// `Transcript`. `Transcript.init` сам никогда не выпустил бы такое значение, поэтому
    /// вход собран `PlistSurgery` — валидный `Transcript` закодирован, один литерал (язык)
    /// заменён на заведомо не-BCP47 текстом, декодирован обратно тем же `EngineWire.decode`,
    /// которым пользуется настоящий транспорт. §3.2: это отказ ДВИЖКА (invalidResult), а не
    /// `serviceUnavailable` — тот зарезервирован за испорченными байтами (тест выше).
    func test_k36_wellFormedFrameWithInvalidTranscriptMapsToEngineFailureInvalidResult() async throws {
        let fixture = try await readyFixture()
        let placeholderJobId = EngineJobId(rawValue: UUID())
        let validTranscript = try Transcript(
            recordingId: UUID(), language: "xy", engine: "fake-engine", modelVersion: "v1",
            createdAt: Date(), segments: [], speakers: []
        )
        let reply = EngineReply.transcript(placeholderJobId, validTranscript)
        let corruptedData = try PlistSurgery.data(
            for: reply, replacing: "<string>xy</string>", with: "<string>9</string>"
        )
        fixture.service.forcedRawResponse = (data: corruptedData, error: nil)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался engineFailure(invalidResult)")
        } catch TranscriptionServiceError.engineFailure(let code, let message) {
            XCTAssertEqual(code, "invalidResult")
            XCTAssertTrue(message.contains("language"), message)
        }
    }

    // MARK: - К37: код engineFailure — имя случая дословно; незапрошенная отмена

    func test_k37_engineFailureCodeNamedAfterEngineErrorCase() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedReplyOverride = { jobId in
            .failed(jobId, .modelIncompatible(modelId: "m", message: "бага"))
        }

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался engineFailure")
        } catch TranscriptionServiceError.engineFailure(let code, _) {
            XCTAssertEqual(code, "modelIncompatible")
        }
    }

    func test_k37_unsolicitedCancelledReplyMapsToCancelled() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedReplyOverride = { jobId in .cancelled(jobId) }

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался cancelled")
        } catch TranscriptionServiceError.cancelled {
            // ожидаемо
        }
    }

    // MARK: - К39: разобранный кадр, не подходящий ни одной строке §3.2

    func test_k39_unmappedParsedReplyGivesServiceUnavailable() async throws {
        let fixture = try await readyFixture()
        // `.pong` в ответ на `.transcribe` — разобрано штатно, но не подходит ни одному
        // ожидаемому виду ответа для этого вызова.
        fixture.service.forcedReplyOverride = { _ in
            .pong(serviceVersion: "x", protocolVersion: EngineWire.protocolVersion)
        }

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    // MARK: - К50: единственные два пути к invalidRequest — не третий через NSCocoaErrorDomain

    /// К50: `invalidRequest` образуется только кодом транспорта `3` (К32) и нераспознанным
    /// кодом `4` (К33) — третьего пути нет. Здесь — прямое доказательство: ЛЮБОЙ код домена
    /// `NSCocoaErrorDomain` (даже не входящий в четыре вектора К51) уходит в `mapCocoaConnectionError`,
    /// который `invalidRequest` не возвращает никогда, только `serviceCrashed`/`serviceUnavailable`.
    func test_k50_arbitraryCocoaDomainCodeNeverMapsToInvalidRequest() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (
            data: nil, error: NSError(domain: NSCocoaErrorDomain, code: 999_999)
        )

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable, не invalidRequest")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо — К51(iv): любой не названный явно код домена уходит сюда, не в invalidRequest
        }
    }

    // MARK: - К51: четыре вектора NSCocoaErrorDomain настоящего NSXPCConnection

    /// К51(i): `NSXPCConnectionInterrupted` (реальный код, каким его несёт настоящий
    /// `NSXPCConnection.remoteObjectProxyWithErrorHandler`) → `serviceCrashed`, тем же путём,
    /// что интерпретирует `connectionDied(crashed: true)` на уровне соединения (К29), но
    /// здесь — на уровне ОДНОГО отказавшего вызова (`map(nsError:)`), не всего соединения.
    func test_k51_cocoaConnectionInterruptedMapsToServiceCrashed() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (
            data: nil, error: NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)
        )

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceCrashed")
        } catch TranscriptionServiceError.serviceCrashed {
            // ожидаемо
        }
    }

    /// К51(ii): `NSXPCConnectionInvalid` → `serviceUnavailable`.
    func test_k51_cocoaConnectionInvalidMapsToServiceUnavailable() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (
            data: nil, error: NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)
        )

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    /// К51(iii): `NSXPCConnectionReplyInvalid` → тот же `serviceUnavailable`.
    func test_k51_cocoaConnectionReplyInvalidMapsToServiceUnavailable() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (
            data: nil, error: NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid)
        )

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    /// К51(iv): любой другой код `NSCocoaErrorDomain` → `serviceUnavailable(message: "<домен>
    /// <код>: <описание>")`, тем же форматом, что общий постор-случай (`describe(_:)`); этот
    /// же вектор закрывает бывший К50(iii) — третьего пути к `invalidRequest` из этого домена нет.
    func test_k51_otherCocoaDomainCodeMapsToServiceUnavailableWithDomainCodeDescription() async throws {
        let fixture = try await readyFixture()
        // Код заведомо вне кластера NSXPCConnection* (4097/4099/4101) — этот вектор
        // проверяет фолбэк на «постороннее», не один из трёх названных кодов.
        let arbitraryCode = 5_000_000
        let error = NSError(
            domain: NSCocoaErrorDomain, code: arbitraryCode, userInfo: [NSLocalizedDescriptionKey: "нечто постороннее"]
        )
        fixture.service.forcedRawResponse = (data: nil, error: error)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable(let message) {
            XCTAssertEqual(message, "\(NSCocoaErrorDomain) \(arbitraryCode): нечто постороннее")
        }
    }
}
