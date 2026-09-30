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
        let transcript = try await run(try request([try audioRef(.system), try audioRef(.mic)]))

        try transcript.validate()
        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.channel == .system })
        XCTAssertEqual(transcript, systemOnly)
        XCTAssertEqual(transcript.speakers.map(\.cluster), [0])
        XCTAssertFalse(source.requestedChannels.contains(.mic))
    }

    // Критерий 2: системный канал без кадров — сегменты микрофона без кластера, `speakers` пуст.
    func testEmptySystemChannelLeavesMicSegmentsIntact() async throws {
        source.durations[recordingId] = 45_000
        let micOnly = try await run(try request([try audioRef(.mic)]))

        source.channelDurations[.system] = 0
        let transcript = try await run(try request([try audioRef(.system), try audioRef(.mic)]))

        try transcript.validate()
        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.channel == .mic && $0.speakerCluster == nil })
        XCTAssertEqual(transcript, micOnly)
        XCTAssertEqual(transcript.speakers, [])
        XCTAssertFalse(source.requestedChannels.contains(.system))
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

        XCTAssertEqual(transcript.segments, [])
        XCTAssertEqual(transcript.speakers, [])
    }
}
