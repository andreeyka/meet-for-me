//  К24, К41, К42 — C-012 §2 (кодирование) и §2.1 (`normalizingDates`). Тексты критериев —
//  MEE-370 (перечень QA), дословно по формулировкам «Вход»/«Ответ».
//
//  Допуск 1e-4, не 1e-6: `Date(timeIntervalSince1970:)` считает через смещение к 2001 году
//  (~978 млн секунд) — округление до миллисекунды и обратное чтение `timeIntervalSince1970`
//  теряют точность ~1e-5 на этом пути (обнаружено CI, прогон 36048940544). 1e-4 всё ещё на
//  порядок меньше миллисекунды (1e-3) — различающая сила «округлено»/«не округлено»
//  сохранена целиком.

import XCTest
import DomainCore
import DomainTestKit
import EngineKit

final class EngineWireRoundTripTests: XCTestCase {

    // MARK: - К24 (инв. 14)

    func test_k24_wireRoundTripsTranscribeRequestWithFilledOptionals() throws {
        let jobId = EngineJobId(rawValue: UUID())
        let request = try TranscriptionRequest(
            audio: [try EngineFixtures.audioRef()], language: "ru", wantWordTimestamps: true,
            asrModel: EngineFixtures.modelBundle(role: .asr), vadModel: EngineFixtures.modelBundle(role: .vad)
        )
        let original = EngineRequest.transcribe(jobId, request)
        let data = try EngineWire.encode(original)

        // Двоичный формат PropertyListEncoder, не JSON — magic-байты "bplist00" отличают его.
        let signature = [UInt8](data.prefix(8))
        XCTAssertEqual(signature, Array("bplist00".utf8), "формат провода — двоичный plist, не JSON")

        let decoded = try EngineWire.decode(EngineRequest.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - К41 (инв. 16)

    private func makeTranscript(createdAt: Date) throws -> Transcript {
        try Transcript(
            recordingId: EngineFixtures.recordingId, language: "en", engine: "fake-asr",
            modelVersion: "v1", createdAt: createdAt, segments: [], speakers: []
        )
    }

    func test_k41_normalizingDatesRoundsCreatedAtToNearestMillisecond() throws {
        let jobId = EngineJobId(rawValue: UUID())
        let transcript = try makeTranscript(createdAt: Date(timeIntervalSince1970: 1_000.123_456_789))
        let normalized = try EngineWire.normalizingDates(.transcript(jobId, transcript))
        guard case .transcript(_, let rounded) = normalized else {
            return XCTFail("ожидался .transcript")
        }
        let milliseconds = rounded.createdAt.timeIntervalSince1970 * 1_000
        XCTAssertEqual(milliseconds, milliseconds.rounded(), accuracy: 1e-4, "кратно миллисекунде")
    }

    /// Отправлено МИМО `normalizingDates` — доказывает, что округляет именно она, а не
    /// транспорт незаметно для всех.
    func test_k41_bypassingNormalizingDatesKeepsSubMillisecondFraction() throws {
        let jobId = EngineJobId(rawValue: UUID())
        let original = Date(timeIntervalSince1970: 1_000.123_456_789)
        let transcript = try makeTranscript(createdAt: original)
        let data = try EngineWire.encode(EngineReply.transcript(jobId, transcript))
        let decoded = try EngineWire.decode(EngineReply.self, from: data)
        guard case .transcript(_, let roundTripped) = decoded else {
            return XCTFail("ожидался .transcript")
        }
        XCTAssertEqual(roundTripped.createdAt.timeIntervalSince1970, original.timeIntervalSince1970,
                       accuracy: 1e-4, "доля миллисекунды сохранена без вызова normalizingDates")
    }

    /// Направление внутрь (`EngineRequest`) не нормализуется — правило действует только наружу.
    func test_k41_engineRequestDateIsNeverNormalized() throws {
        let jobId = EngineJobId(rawValue: UUID())
        let original = Date(timeIntervalSince1970: 1_000.123_456_789)
        let transcript = try makeTranscript(createdAt: original)
        let request = EngineRequest.postProcess(jobId, try EngineFixtures.postProcessRequest(transcript: transcript))
        let data = try EngineWire.encode(request)
        let decoded = try EngineWire.decode(EngineRequest.self, from: data)
        guard case .postProcess(_, let payload) = decoded else {
            return XCTFail("ожидался .postProcess")
        }
        XCTAssertEqual(payload.transcript.createdAt.timeIntervalSince1970, original.timeIntervalSince1970,
                       accuracy: 1e-4, "EngineRequest не нормализуется")
    }

    // MARK: - К42 (инв. 21)

    func test_k42_normalizingDatesNeverThrowsOnValidFixtures() throws {
        for fixture in TranscriptFixtures.allFixtures {
            let jobId = EngineJobId(rawValue: UUID())
            let normalized = try EngineWire.normalizingDates(.transcript(jobId, fixture))
            guard case .transcript(_, let rounded) = normalized else {
                XCTFail("ожидался .transcript")
                continue
            }
            XCTAssertEqual(rounded.recordingId, fixture.recordingId)
            XCTAssertEqual(rounded.segments, fixture.segments)
            XCTAssertEqual(rounded.speakers, fixture.speakers)
            let milliseconds = rounded.createdAt.timeIntervalSince1970 * 1_000
            XCTAssertEqual(milliseconds, milliseconds.rounded(), accuracy: 1e-4)
        }
    }
}
