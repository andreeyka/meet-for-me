//  GigaAMEngineFlowTests — MEE-502 (Z3б): критерии 6–8 (отмена, прогресс, ошибки) на фейках.

import DomainCore
import DomainTestKit
import EngineKit
import Foundation
import XCTest
@testable import GigaAM

final class GigaAMEngineFlowTests: GigaAMEngineTestCase {

    // Критерий 6
    func testCancellationOnThirdChunk() async throws {
        source.durations[recordingId] = 613_000
        recognizer.cancelOnCall = 3
        let log = ProgressLog()
        let engine = makeEngine()
        let bad = try request([try audioRef(.system)])
        let task = Task { try await self.run(bad, log: log, engine: engine) }
        do {
            _ = try await task.value
            XCTFail("ожидалась cancelled")
        } catch {
            XCTAssertEqual(error as? EngineError, .cancelled)
        }
        XCTAssertEqual(recognizer.calls.count, 3)
        XCTAssertFalse(log.events.contains(.finished(stage: .asr)))
    }

    // Критерий 7
    func testProgress() async throws {
        source.durations[recordingId] = 100_000
        let log = ProgressLog()
        _ = try await run(try request([try audioRef(.system)]), log: log)
        let events = log.events
        XCTAssertEqual(events.filter { $0 == .started(stage: .asr) }.count, 1)
        XCTAssertEqual(events.filter { $0 == .finished(stage: .asr) }.count, 1)
        XCTAssertEqual(events.first, .started(stage: .asr))
        XCTAssertEqual(events.last, .finished(stage: .asr))
        var previous = 0.0
        var advances = 0
        for case let .advanced(stage, fraction) in events {
            XCTAssertEqual(stage, .asr)
            XCTAssertTrue((0...1).contains(fraction))
            XCTAssertGreaterThanOrEqual(fraction, previous)
            previous = fraction
            advances += 1
        }
        XCTAssertEqual(advances, recognizer.calls.count)
        XCTAssertEqual(previous, 1.0, accuracy: 1e-9)
    }

    func testProgressFractionCoversBothChannels() async throws {
        source.durations[recordingId] = 20_000
        let log = ProgressLog()
        _ = try await run(try request([try audioRef(.system), try audioRef(.mic)]), log: log)
        let fractions = log.events.compactMap { event -> Double? in
            if case let .advanced(_, fraction) = event { return fraction }
            return nil
        }
        XCTAssertEqual(fractions, [0.5, 1.0])
    }

    // Критерий 8
    func testErrors() async throws {
        source.durations[recordingId] = 10_000
        let ref = try audioRef(.system)
        let log = ProgressLog()

        recognizer.failure = GigaAMRecognizerError.runtimeFailure(message: "boom")
        do {
            _ = try await run(try request([ref]), log: log)
            XCTFail("ожидалась runtimeFailure")
        } catch {
            XCTAssertEqual(error as? EngineError, .runtimeFailure(message: "boom"))
        }
        recognizer.failure = nil

        for passthrough in [EngineError.audioUnreadable(path: "/audio/system.wav"),
                            EngineError.unsupportedRequest(message: "sampleRate 44100")] {
            source.failure = passthrough
            await assertEngineError(passthrough, try request([ref]))
        }
        source.failure = nil
        XCTAssertFalse(log.events.contains(.finished(stage: .asr)))
    }

    func testTranscriptInitFailureBecomesInvalidResult() async throws {
        // два потока одного канала перекрываются — инвариант 14 C-003 не даёт собрать Transcript
        source.durations[recordingId] = 10_000
        let refs = [try audioRef(.mic), try audioRef(.mic)]
        do {
            _ = try await run(try request(refs))
            XCTFail("ожидалась invalidResult")
        } catch let error as EngineError {
            guard case .invalidResult = error else { return XCTFail("\(error)") }
        }
    }
}
