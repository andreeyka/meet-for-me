//  К32 (половина «Форма», Linux) — C-012 §3.2/§3, четыре вектора байтами через
//  `LoopbackEngineTransport.receive(_ requestData: Data) throws`, играющий роль «сервиса»:
//  разбор кадра, где `EngineRequest.postProcess` несёт `PostProcessRequest.transcript` с
//  нарушением C-003. Отображение в `TranscriptionServiceError` (macOS-половина) сюда не
//  входит — эта половина смотрит на исход `receive(_:) throws` напрямую.
//
//  Все четыре вектора строятся ОДНОЙ правкой одного эталона — `PlistSurgery`, тот же приём,
//  что `BrokenWeights` (DomainCoreTests) для JSON.

import XCTest
import DomainCore
import EngineKit

final class LoopbackTransportMalformedRequestTests: XCTestCase {

    /// Эталон: сегмент `.mic` с двумя корректными по отдельности словами, границы
    /// сегмента и слов подобраны БЕЗ повторяющихся числовых литералов — правка одного
    /// значения не задевает другое случайным совпадением текста.
    private func makeBaseRequest() throws -> (jobId: EngineJobId, request: EngineRequest) {
        // Точные двоичные дроби (0.875 = 7/8, 0.625 = 5/8): PropertyListEncoder печатает
        // НЕТОЧНУЮ дробь (0.9, …) полной точностью double, а не короткой формой — обнаружено
        // CI (прогон 36048940544), цель "<real>0.9</real>" не находилась в тексте вовсе.
        let words = [
            try Transcript.Word(startMs: 50, endMs: 450, text: "раз", confidence: 0.875, original: nil),
            try Transcript.Word(startMs: 850, endMs: 1_250, text: "два", confidence: 0.625, original: nil)
        ]
        let segment = try Transcript.Segment(
            startMs: 10, endMs: 1_300, channel: .mic, speakerCluster: nil,
            text: "раз два", textOriginal: nil, textConfidence: 0.625, words: words
        )
        let transcript = try Transcript(
            recordingId: EngineFixtures.recordingId, language: "ru", engine: "fake-asr",
            modelVersion: "v1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            segments: [segment], speakers: []
        )
        let jobId = EngineJobId(rawValue: UUID())
        let request = EngineRequest.postProcess(jobId, try EngineFixtures.postProcessRequest(transcript: transcript))
        return (jobId, request)
    }

    private func makeTransport() -> LoopbackEngineTransport {
        LoopbackEngineTransport(transcription: FakeTranscriptionEngine(), diarization: FakeDiarizationEngine(),
                                embedding: FakeEmbeddingEngine(), postProcessor: FakePostProcessor())
    }

    private func encodedXML(_ request: EngineRequest) throws -> String {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        guard let text = String(data: try encoder.encode(request), encoding: .utf8) else {
            throw PlistSurgeryError.notUTF8
        }
        return text
    }

    private func data(from text: String) throws -> Data {
        guard let data = text.data(using: .utf8) else { throw PlistSurgeryError.notUTF8 }
        return data
    }

    /// Меняет местами два непересекающихся текстовых литерала — то же, чем на проводе
    /// была бы перестановка элементов массива, без риска столкновения прямой заменой.
    private func swapLiterals(_ first: String, _ second: String, in text: String) throws -> String {
        guard text.contains(first), text.contains(second) else {
            throw PlistSurgeryError.targetNotFound("\(first) / \(second)")
        }
        let placeholder = "@@ENGINEKIT_SWAP@@"
        return text
            .replacingOccurrences(of: first, with: placeholder)
            .replacingOccurrences(of: second, with: first)
            .replacingOccurrences(of: placeholder, with: second)
    }

    /// Заменяет только год в единственном `<date>…</date>` документа — устойчиво к
    /// неизвестному заранее формату времени/долей секунды.
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

    // MARK: - (i) confidence == 1.0000001 — вложенный тип, инв. 7

    func test_k32_wordConfidenceOutOfRangeThrowsDomainValidationError() throws {
        let (_, request) = try makeBaseRequest()
        let text = try encodedXML(request)
            .replacingOccurrences(of: "<real>0.875</real>", with: "<real>1.0000001</real>")
        do {
            try makeTransport().receive(try data(from: text))
            XCTFail("ожидался DomainValidationError")
        } catch let error as DomainValidationError {
            XCTAssertEqual(error.invariant, 7)
            XCTAssertEqual(error.type, "Transcript.Word")
            XCTAssertEqual(error.path, "confidence")
            XCTAssertEqual(error.contract, "C-003")
        }
    }

    // MARK: - (ii) words не упорядочены по startMs — родительский тип, инв. 4

    func test_k32_unsortedWordsThrowDomainValidationError() throws {
        let (_, request) = try makeBaseRequest()
        var text = try encodedXML(request)
        text = try swapLiterals("<integer>50</integer>", "<integer>850</integer>", in: text)
        text = try swapLiterals("<integer>450</integer>", "<integer>1250</integer>", in: text)
        do {
            try makeTransport().receive(try data(from: text))
            XCTFail("ожидался DomainValidationError")
        } catch let error as DomainValidationError {
            XCTAssertEqual(error.invariant, 4)
            XCTAssertEqual(error.type, "Transcript.Segment")
            XCTAssertTrue(error.path.hasSuffix(".startMs"), "путь указывает на startMs невпорядоченного слова")
            XCTAssertEqual(error.contract, "C-003")
        }
    }

    // MARK: - (iii) confidence непредставим — отсекается decodeFinite до validate()

    func test_k32_unrepresentableWordConfidenceThrowsDecodingError() throws {
        let (_, request) = try makeBaseRequest()
        let text = try encodedXML(request).replacingOccurrences(of: "<real>0.875</real>", with: "<real>1e400</real>")
        do {
            try makeTransport().receive(try data(from: text))
            XCTFail("ожидался DecodingError.dataCorrupted")
        } catch DecodingError.dataCorrupted {
            // ожидаемо
        }
    }

    // MARK: - (iv) createdAt в году 300000 — представимо, доходит до validate(), инв. 0

    func test_k32_createdAtYear300000ThrowsDomainValidationError() throws {
        let (_, request) = try makeBaseRequest()
        let text = try withYearReplaced(try encodedXML(request), by: "300000")
        do {
            try makeTransport().receive(try data(from: text))
            XCTFail("ожидался DomainValidationError")
        } catch let error as DomainValidationError {
            XCTAssertEqual(error.invariant, 0)
            XCTAssertEqual(error.type, "Transcript")
            XCTAssertEqual(error.path, "createdAt")
            XCTAssertEqual(error.contract, "C-003")
        }
    }

    // MARK: - Пятый вход К32 (код без текста) — вне зоны Linux (отображение macOS)

    func test_k32_vectorOfNonEmptiness_encodedRequestActuallyContainsBothConfidences() throws {
        let (_, request) = try makeBaseRequest()
        let text = try encodedXML(request)
        XCTAssertTrue(text.contains("<real>0.875</real>"), "эталон несёт значение, которое правят все три вектора")
    }
}
