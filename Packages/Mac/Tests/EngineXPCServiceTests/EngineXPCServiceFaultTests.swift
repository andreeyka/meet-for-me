//  EngineXPCServiceFaultTests — MEE-438, C-012 v10 §3.1/§3.2, через `rawServiceProxy` (сырой
//  `EngineXPCServiceProtocol`, в обход `EngineXPCClient`, у которого свой ПРЕДВАРИТЕЛЬНЫЙ
//  контроль размера — К25, MEE-431 — до всякого обращения к транспорту, так что этот путь
//  сервиса им никогда не упражняется).
//
//  §3.1 код 2: сервис обязан отказывать ПРЕВЫШЕНИЕ РАЗМЕРА ВХОДЯЩЕГО кадра самостоятельно —
//  не полагаясь на то, что единственный сегодняшний клиент уже проверил его сам.
//
//  §3.2 (К32, четыре вектора, отложенные из PR #165/МЕЕ-431 до появления настоящего сервиса):
//  ОДНА точка разбора — `EngineWire.decode(EngineRequest.self, from:)` внутри
//  `EngineXPCRequestHandler.handle`; выбор префикса «decoding: »/«invariant: » — по
//  брошенному ТИПУ. Векторы (i)…(iv) — те же самые, что уже доказаны на уровне EngineKit/Linux
//  (`LoopbackTransportMalformedRequestTests`, `receive(_:) throws` напрямую): здесь
//  проверяется НЕ throwing-поведение decode (уже доказано там), а СОБСТВЕННАЯ, НОВАЯ
//  обязанность стороны сервиса — завернуть тот же брошенный `DomainValidationError`/
//  `DecodingError` в `NSError(EngineTransportFault.errorDomain, code: invalidRequest)` с
//  правильным префиксом, доставленную по НАСТОЯЩЕМУ `NSXPCConnection`.
//
//  РАСКРЫТИЕ по возврату РП (MEE-438, 11:50 UTC):
//  * проверки текста ниже — `.contains(...)` над структурными полями (`invariant`/`contract`/
//    `type`/путь), не равенство целой строки: `DomainValidationError.message` контрактом прямо
//    назван нестабильным и сравнению не подлежит (`DomainValidationError.swift`, §0.1) — тот же
//    выбор, что уже стоял в `LoopbackTransportMalformedRequestTests` (Core/EngineKitTests) для
//    этих же четырёх векторов;
//  * вектор (iii) использует `1e400` (буквально непредставимое `Double`, отсекается
//    `decodeFinite` до `validate()`), а не `NaN` — `PropertyListEncoder`/XML не несёт литерала
//    NaN уместно для текстовой правки этого приёма (`PlistSurgery`), `1e400` — тот же самый
//    вход, каким уже доказан этот путь на EngineKit/Linux-половине (см. файл выше).

import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCServiceFaultTests: XCTestCase {

    // MARK: - §3.1 код 2: сервис сам ловит превышение размера входящего кадра

    func test_serviceIndependentlyRejectsOversizedIncomingRequest() async throws {
        let fixture = RealServiceFixture()
        let (proxy, connection) = fixture.rawServiceProxy()
        defer { connection.invalidate() }
        let hugeData = Data(count: EngineWire.maxMessageBytes + 1)

        let (data, error) = await send(proxy, hugeData)

        XCTAssertNil(data)
        let nsError = try XCTUnwrap(error)
        XCTAssertEqual(nsError.domain, EngineTransportFault.errorDomain)
        XCTAssertEqual(nsError.code, EngineTransportFault.messageTooLarge.rawValue)
        XCTAssertEqual(nsError.userInfo[EngineTransportFault.messageBytesKey] as? Int, hugeData.count)
    }

    // MARK: - Эталон К32 (тот же приём, что LoopbackTransportMalformedRequestTests)

    private func makeBaseRequest() throws -> (jobId: EngineJobId, request: EngineRequest) {
        let words = [
            try Transcript.Word(startMs: 50, endMs: 450, text: "раз", confidence: 0.875, original: nil),
            try Transcript.Word(startMs: 850, endMs: 1_250, text: "два", confidence: 0.625, original: nil)
        ]
        let segment = try Transcript.Segment(
            startMs: 10, endMs: 1_300, channel: .mic, speakerCluster: nil,
            text: "раз два", textOriginal: nil, textConfidence: 0.625, words: words
        )
        let transcript = try Transcript(
            recordingId: ServiceFixtures.recordingId, language: "ru", engine: "fake-asr",
            modelVersion: "v1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            segments: [segment], speakers: []
        )
        let jobId = EngineJobId(rawValue: UUID())
        let request = EngineRequest.postProcess(jobId, try ServiceFixtures.postProcessRequest(transcript: transcript))
        return (jobId, request)
    }

    private func withYearReplaced(_ text: String, by newYear: String) throws -> String {
        guard let open = text.range(of: "<date>"),
              let close = text.range(of: "</date>", range: open.upperBound..<text.endIndex) else {
            throw PlistSurgeryError.targetNotFound("<date>")
        }
        let original = text[open.upperBound..<close.lowerBound]
        guard let dash = original.firstIndex(of: "-") else {
            throw PlistSurgeryError.targetNotFound("год в \(original)")
        }
        let replacedDate = newYear + original[dash...]
        return text.replacingOccurrences(of: "<date>\(original)</date>", with: "<date>\(replacedDate)</date>")
    }

    /// (i) confidence == 1.0000001 — инв. 7, `Transcript.Word` → «invariant: C-003.Transcript.Word
    /// инв. 7, confidence: …».
    func test_k32i_wordConfidenceOutOfRangeMapsToInvalidRequestWithInvariantPrefix() async throws {
        let fixture = RealServiceFixture()
        let (proxy, connection) = fixture.rawServiceProxy()
        defer { connection.invalidate() }
        let (_, request) = try makeBaseRequest()
        let xml = try PlistSurgery.xml(for: request)
        let data = try PlistSurgery.replacing(xml, "<real>0.875</real>", with: "<real>1.0000001</real>")

        let (replyData, error) = await send(proxy, data)

        XCTAssertNil(replyData)
        let nsError = try XCTUnwrap(error)
        XCTAssertEqual(nsError.domain, EngineTransportFault.errorDomain)
        XCTAssertEqual(nsError.code, EngineTransportFault.invalidRequest.rawValue)
        let message = try XCTUnwrap(nsError.userInfo[NSLocalizedDescriptionKey] as? String)
        XCTAssertTrue(message.hasPrefix("invariant: "), message)
        XCTAssertTrue(message.contains("C-003.Transcript.Word инв. 7, confidence:"), message)
    }

    /// (ii) слова не упорядочены по startMs — инв. 4, `Transcript.Segment`.
    func test_k32ii_unsortedWordsMapsToInvalidRequestWithInvariantPrefix() async throws {
        let fixture = RealServiceFixture()
        let (proxy, connection) = fixture.rawServiceProxy()
        defer { connection.invalidate() }
        let (_, request) = try makeBaseRequest()
        let firstSwap = try PlistSurgery.swapping(
            try PlistSurgery.xml(for: request), "<integer>50</integer>", "<integer>850</integer>"
        )
        let firstSwapText = try XCTUnwrap(String(data: firstSwap, encoding: .utf8))
        let data = try PlistSurgery.swapping(firstSwapText, "<integer>450</integer>", "<integer>1250</integer>")

        let (replyData, error) = await send(proxy, data)

        XCTAssertNil(replyData)
        let nsError = try XCTUnwrap(error)
        XCTAssertEqual(nsError.code, EngineTransportFault.invalidRequest.rawValue)
        let message = try XCTUnwrap(nsError.userInfo[NSLocalizedDescriptionKey] as? String)
        XCTAssertTrue(message.hasPrefix("invariant: "), message)
        XCTAssertTrue(message.contains("C-003.Transcript.Segment инв. 4,"), message)
        XCTAssertTrue(message.contains(".startMs:"), message)
    }

    /// (iii) confidence непредставим (`1e400`) — отсекается `decodeFinite` до `validate()` —
    /// `DecodingError`, префикс «decoding: », НЕ «invariant: ».
    func test_k32iii_unrepresentableConfidenceMapsToInvalidRequestWithDecodingPrefix() async throws {
        let fixture = RealServiceFixture()
        let (proxy, connection) = fixture.rawServiceProxy()
        defer { connection.invalidate() }
        let (_, request) = try makeBaseRequest()
        let xml = try PlistSurgery.xml(for: request)
        let data = try PlistSurgery.replacing(xml, "<real>0.875</real>", with: "<real>1e400</real>")

        let (replyData, error) = await send(proxy, data)

        XCTAssertNil(replyData)
        let nsError = try XCTUnwrap(error)
        XCTAssertEqual(nsError.code, EngineTransportFault.invalidRequest.rawValue)
        let message = try XCTUnwrap(nsError.userInfo[NSLocalizedDescriptionKey] as? String)
        XCTAssertTrue(message.hasPrefix("decoding: "), message)
    }

    /// (iv) createdAt в году 300000 — представимо, доходит до `validate()`, инв. 0, `Transcript`.
    func test_k32iv_createdAtYear300000MapsToInvalidRequestWithInvariantPrefix() async throws {
        let fixture = RealServiceFixture()
        let (proxy, connection) = fixture.rawServiceProxy()
        defer { connection.invalidate() }
        let (_, request) = try makeBaseRequest()
        let text = try withYearReplaced(try PlistSurgery.xml(for: request), by: "300000")
        let data = try XCTUnwrap(text.data(using: .utf8))

        let (replyData, error) = await send(proxy, data)

        XCTAssertNil(replyData)
        let nsError = try XCTUnwrap(error)
        XCTAssertEqual(nsError.code, EngineTransportFault.invalidRequest.rawValue)
        let message = try XCTUnwrap(nsError.userInfo[NSLocalizedDescriptionKey] as? String)
        XCTAssertTrue(message.hasPrefix("invariant: "), message)
        XCTAssertTrue(message.contains("C-003.Transcript инв. 0, createdAt:"), message)
    }
}
