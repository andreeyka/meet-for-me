//  GigaAMEngineSpeechOnsetTests — MEE-513 (IR-157), критерий 3: начало энергии действует для каждого
//  куска дорожки, включая первый. Фейковый распознаватель, как sherpa-onnx, ставит первый токен на кадр 0.
//  MEE-514: кусок без токенов-слов — начало энергии не считается.

import DomainCore
import DomainTestKit
import EngineKit
import Foundation
import XCTest
@testable import GigaAM

final class GigaAMEngineSpeechOnsetTests: GigaAMEngineTestCase {

    /// Запись начинается с 700 мс тишины — первое слово не раньше 680 мс (и не позже 700 мс).
    func testRecordingStartingWithSilenceFirstWordNotBefore680() async throws {
        source.leadingSilenceMs = 700
        source.durations[recordingId] = 5_000
        for words in [true, false] {
            let transcript = try await run(try request([try audioRef(.system)], words: words))
            let start = try XCTUnwrap(transcript.segments.first?.startMs)
            XCTAssertTrue((680...700).contains(start), "\(start)")
            if words {
                XCTAssertEqual(transcript.segments.first?.words.first?.startMs, start)
            }
        }
    }

    /// Начало со сдвигом `offsetMs`: к началу энергии прибавляется, как к остальным меткам.
    func testOnsetIsShiftedByOffset() async throws {
        source.leadingSilenceMs = 700
        source.durations[recordingId] = 5_000
        let transcript = try await run(try request([try audioRef(.mic, offsetMs: 1_500)]))
        let start = try XCTUnwrap(transcript.segments.first?.startMs)
        XCTAssertTrue((2_180...2_200).contains(start), "\(start)")
    }

    /// Каждый кусок: если он начался в тишине (400 мс каждые 4,7 с), первое слово — у конца тишины
    /// (в пределах окна 20 мс), иначе — на начале куска. Позиции кусков — по длинам входа распознавателя.
    func testEveryChunkFirstWordStartsAtSpeech() async throws {
        source.durations[recordingId] = 200_000
        let transcript = try await run(try request([try audioRef(.system)]))
        let positions = recognizer.calls.reduce(into: [0]) { $0.append($0.last! + $1 / 16) }.dropLast()
        XCTAssertGreaterThan(positions.count, 6)
        XCTAssertEqual(transcript.segments.count, positions.count)
        var startedInSilence = 0
        for (segment, position) in zip(transcript.segments, positions) {
            if source.isSilent(atMs: position) {
                startedInSilence += 1
                let speech = (position / 4_700) * 4_700 + 400
                XCTAssertTrue(
                    (speech - 20...speech).contains(segment.startMs), "кусок с \(position): \(segment.startMs)"
                )
            } else {
                XCTAssertEqual(segment.startMs, position)
            }
        }
        // шов приходится на самую тихую точку — все куски, кроме первого, начались в тишине;
        // первый тоже: дорожка источника начинается с 400 мс тишины
        XCTAssertEqual(startedInSilence, positions.count)
    }

    /// Кусок без токенов или из одних знаков препинания: подменять нечего, энергия не считается — `nil`
    /// даже при громком сигнале с первого отсчёта. Для сравнения — тот же сигнал с одним словом даёт 0.
    func testChunkWithoutWordTokensHasNoOnset() {
        let loud = [Float](repeating: 0.5, count: 16_000)
        let empty = RecognizedChunk(text: "", tokens: [], timestamps: [])
        let punctuation = RecognizedChunk(text: ".", tokens: [".", "▁,"], timestamps: [0, 0.2])
        XCTAssertNil(GigaAMEngine.chunkOnsetMs(samples: loud, chunk: empty))
        XCTAssertNil(GigaAMEngine.chunkOnsetMs(samples: loud, chunk: punctuation))
        let word = RecognizedChunk(text: "да", tokens: ["▁да"], timestamps: [0])
        XCTAssertEqual(GigaAMEngine.chunkOnsetMs(samples: loud, chunk: word), 0)
    }
}
