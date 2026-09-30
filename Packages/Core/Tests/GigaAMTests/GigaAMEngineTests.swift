//  GigaAMEngineTests — MEE-502 (Z3б): критерии 1–5 и 9–11 решения IR-152 на фейках, без модели и без сети.

import DomainCore
import DomainTestKit
import EngineKit
import Foundation
import XCTest
@testable import GigaAM

final class GigaAMEngineTests: GigaAMEngineTestCase {

    // Требования к движку
    func testEngineIdAndLanguages() {
        let engine = makeEngine()
        XCTAssertEqual(engine.engineId, "gigaam-sherpa-onnx")
        XCTAssertEqual(GigaAMEngine.engineId, "gigaam-sherpa-onnx")
        XCTAssertEqual(engine.supportedLanguages(), ["ru"])
    }

    // Критерий 1
    func testDifferentRecordingIdsAreUnsupported() async throws {
        let other = UUID()
        source.durations[other] = 1_000
        let refs = [try audioRef(.system), try audioRef(.mic, id: other)]
        let bad = try request(refs)
        do {
            _ = try await run(bad)
            XCTFail("ожидалась unsupportedRequest")
        } catch let error as EngineError {
            guard case .unsupportedRequest = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(source.requestCount, 0)
    }

    // Критерий 2
    func testLanguage() async throws {
        source.durations[recordingId] = 3_000
        let ref = try audioRef(.system)
        await assertEngineError(.unsupportedLanguage("en"), try request([ref], language: "en"))
        for language in [nil, "ru"] {
            let transcript = try await run(try request([ref], language: language))
            XCTAssertEqual(transcript.language, "ru")
        }
    }

    // Критерий 3
    func testModelMissingBeforeAnyAudioRead() async throws {
        source.durations[recordingId] = 3_000
        let ref = try audioRef(.system)
        let expected = EngineError.modelMissing(modelId: "gigaam-v3-e2e-ctc-int8", version: "3.0.0")
        for name in [GigaAMEngine.modelFileName, GigaAMEngine.tokensFileName] {
            try writeModelFiles()
            try FileManager.default.removeItem(at: modelDirectory.appendingPathComponent(name))
            await assertEngineError(expected, try request([ref]))
        }
        XCTAssertEqual(source.requestCount, 0)
        XCTAssertEqual(recognizer.calls, [])
    }

    func testAdapterReportingMissingFilesMapsToModelMissing() async throws {
        source.durations[recordingId] = 3_000
        let engine = makeEngine(factoryFailure: GigaAMRecognizerError.modelFilesMissing)
        let bad = try request([try audioRef(.system)])
        do {
            _ = try await run(bad, engine: engine)
            XCTFail("ожидалась modelMissing")
        } catch {
            XCTAssertEqual(
                error as? EngineError, .modelMissing(modelId: "gigaam-v3-e2e-ctc-int8", version: "3.0.0")
            )
        }
        XCTAssertEqual(source.requestCount, 0)
    }

    // Критерии 4 и 5 (инвариант 19)
    func testSixHundredThirteenSecondsGiveOneTranscript() async throws {
        source.durations[recordingId] = 613_000
        let transcript = try await run(try request([try audioRef(.system)]))
        XCTAssertGreaterThanOrEqual(recognizer.calls.count, 21)
        XCTAssertLessThanOrEqual(recognizer.calls.count, 31)
        XCTAssertLessThanOrEqual(recognizer.calls.max() ?? 0, 30 * 16_000)
        XCTAssertLessThanOrEqual(source.longestRequestMs, 30_000)
        XCTAssertEqual(transcript.segments.count, recognizer.calls.count)
        XCTAssertNoThrow(try transcript.validate())
        XCTAssertLessThan(transcript.segments.last?.endMs ?? Int.max, 613_001)
    }

    // Критерий 9
    func testEngineAndModelVersion() async throws {
        source.durations[recordingId] = 5_000
        let engine = makeEngine()
        let transcript = try await run(try request([try audioRef(.system)]), engine: engine)
        XCTAssertEqual(transcript.engine, engine.engineId)
        XCTAssertEqual(transcript.modelVersion, "3.0.0")
        XCTAssertEqual(transcript.recordingId, recordingId)
        XCTAssertEqual(transcript.createdAt, fixedDate)
    }

    // Критерий 10
    func testTwoChannelsAreMergedByStartMs() async throws {
        source.durations[recordingId] = 5_000
        let system = try audioRef(.system)
        let mic = try audioRef(.mic)
        let first = try await run(try request([system, mic]))
        XCTAssertEqual(first.segments.map(\.channel), [.system, .mic])
        XCTAssertEqual(first.segments.map(\.startMs), [0, 0])
        let second = try await run(try request([mic, system]))
        XCTAssertEqual(second.segments.map(\.channel), [.mic, .system])
    }

    func testOffsetShiftsLabels() async throws {
        source.durations[recordingId] = 5_000
        let mic = try audioRef(.mic, offsetMs: 1_500)
        let transcript = try await run(try request([mic]))
        XCTAssertEqual(transcript.segments.first?.startMs, 1_500)
    }

    // Критерий 11
    func testSystemClusterZeroMicNil() async throws {
        source.durations[recordingId] = 5_000
        let transcript = try await run(try request([try audioRef(.system), try audioRef(.mic)]))
        for segment in transcript.segments {
            XCTAssertEqual(segment.speakerCluster, segment.channel == .system ? 0 : nil)
        }
        let systemMs = transcript.segments.filter { $0.channel == .system }.reduce(0) { $0 + $1.endMs - $1.startMs }
        XCTAssertEqual(transcript.speakers, [
            try Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: systemMs)
        ])
    }

    func testWithoutWordTimestampsWordsAreEmpty() async throws {
        source.durations[recordingId] = 5_000
        let transcript = try await run(try request([try audioRef(.system)], words: false))
        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.words.isEmpty })
    }
}
