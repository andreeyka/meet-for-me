//  GigaAMEngineEmptyTrackTests — MEE-509 (IR-154 п. 1, C-011 v8 инв. 17): дорожка без кадров.
//
//  Файл, у которого заголовок разобран и совпал с `AudioRef`, а кадров нет, — не нечитаемый:
//  `transcribe` по такой дорожке даёт ноль сегментов канала, а не отказ. Порт `GigaAMAudioSource`
//  отдаёт для такого файла длительность 0 мс (`AudioTrackReader.durationMs(of:)` — тест
//  `AudioTrackReaderTruncationTests.testZeroFrameFileReadsAsEmptyTrack` в `Packages/Mac`).

import DomainCore
import DomainTestKit
import EngineKit
import Foundation
import XCTest
@testable import GigaAM

final class GigaAMEngineEmptyTrackTests: GigaAMEngineTestCase {

    // Критерий 2: микрофон без кадров — транскрипт тот же, что по одному системному каналу.
    func testEmptyMicChannelLeavesSystemSegmentsIntact() async throws {
        source.durations[recordingId] = 45_000
        let systemOnly = try await run(try request([try audioRef(.system)]))

        source.channelDurations[.mic] = 0
        let log = ProgressLog()
        let transcript = try await run(try request([try audioRef(.system), try audioRef(.mic)]), log: log)

        try transcript.validate()
        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.channel == .system })
        XCTAssertEqual(transcript, systemOnly)
        XCTAssertEqual(transcript.speakers.map(\.cluster), [0])
        XCTAssertFalse(source.requestedChannels.contains(.mic))
        assertProgressCompletes(log)
    }

    // Критерий 2: системный канал без кадров — сегменты микрофона без кластера, `speakers` пуст.
    func testEmptySystemChannelLeavesMicSegmentsIntact() async throws {
        source.durations[recordingId] = 45_000
        let micOnly = try await run(try request([try audioRef(.mic)]))

        source.channelDurations[.system] = 0
        let log = ProgressLog()
        let transcript = try await run(try request([try audioRef(.system), try audioRef(.mic)]), log: log)

        try transcript.validate()
        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.channel == .mic && $0.speakerCluster == nil })
        XCTAssertEqual(transcript, micOnly)
        XCTAssertEqual(transcript.speakers, [])
        XCTAssertFalse(source.requestedChannels.contains(.system))
        assertProgressCompletes(log)
    }

    // Критерий 3: оба канала без кадров — валидный пустой транскрипт, не отказ.
    func testBothChannelsEmptyGiveEmptyTranscript() async throws {
        source.channelDurations = [.system: 0, .mic: 0]
        let log = ProgressLog()

        let transcript = try await run(try request([try audioRef(.system), try audioRef(.mic)]), log: log)

        try transcript.validate()
        XCTAssertEqual(transcript.segments, [])
        XCTAssertEqual(transcript.speakers, [])
        XCTAssertEqual(transcript.recordingId, recordingId)
        XCTAssertEqual(transcript.engine, GigaAMEngine.engineId)
        XCTAssertEqual(transcript.modelVersion, "3.0.0")
        XCTAssertEqual(recognizer.calls, [])
        XCTAssertEqual(source.requestCount, 0)
        XCTAssertEqual(log.events, [.started(stage: .asr), .finished(stage: .asr)])
    }

    // Критерий 3, один канал в запросе.
    func testSingleEmptyChannelGivesEmptyTranscript() async throws {
        source.channelDurations[.system] = 0

        let transcript = try await run(try request([try audioRef(.system)]))

        try transcript.validate()
        XCTAssertEqual(transcript.segments, [])
        XCTAssertEqual(transcript.speakers, [])
        XCTAssertEqual(recognizer.calls, [])
    }

    // Инварианты 10, 11: отмена при пустых каналах — `cancelled`, без транскрипта и `.finished`.
    func testCancelledBeforeCallWithBothChannelsEmpty() async throws {
        source.channelDurations = [.system: 0, .mic: 0]
        let log = ProgressLog()
        let engine = makeEngine()
        let empty = try request([try audioRef(.system), try audioRef(.mic)])

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.run(empty, log: log, engine: engine)
        }
        do {
            _ = try await task.value
            XCTFail("ожидалась cancelled")
        } catch {
            XCTAssertEqual(error as? EngineError, .cancelled)
        }
        XCTAssertFalse(log.events.contains(.finished(stage: .asr)))
        XCTAssertEqual(recognizer.calls, [])
    }

    /// Последний `advanced` — 1, `.finished` ровно один и последним.
    private func assertProgressCompletes(
        _ log: ProgressLog, file: StaticString = #filePath, line: UInt = #line
    ) {
        let events = log.events
        let fractions = events.compactMap { event -> Double? in
            if case let .advanced(_, fraction) = event { return fraction }
            return nil
        }
        XCTAssertEqual(fractions.last ?? 0, 1.0, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(events.filter { $0 == .finished(stage: .asr) }.count, 1, file: file, line: line)
        XCTAssertEqual(events.last, .finished(stage: .asr), file: file, line: line)
    }
}
