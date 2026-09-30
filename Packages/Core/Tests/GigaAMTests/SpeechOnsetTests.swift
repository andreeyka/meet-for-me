//  SpeechOnsetTests — MEE-513 (IR-157), критерии 1 и 7: начало энергии в куске по правилу module-map
//  v1.23 «Метка первого слова куска», на синтетике, без модели.

import Foundation
import XCTest
@testable import GigaAM

final class SpeechOnsetTests: XCTestCase {

    private let rate = SpeechOnset.sampleRate

    /// Тон 440 Гц амплитуды `amplitude` после `silenceMs` мс цифровой тишины; всего `totalMs` мс.
    private func tone(afterMs silenceMs: Int, totalMs: Int = 3_000, amplitude: Float = 0.3) -> [Float] {
        let silence = silenceMs * rate / 1_000
        return (0..<(totalMs * rate / 1_000)).map { index in
            guard index >= silence else { return 0 }
            let time = Double(index - silence) / Double(rate)
            return amplitude * Float(sin(2 * Double.pi * 440 * time))
        }
    }

    /// Шум: равномерный в ±√3·rms (RMS ≈ `rms`), детерминированный.
    private func noise(rms: Float, count: Int) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let scale = rms * Float(3).squareRoot()
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)
            return (unit * 2 - 1) * scale
        }
    }

    // Критерий 1: тишина + тон — в пределах одного окна от начала тона
    func testOnsetWithinOneWindowOfToneStart() throws {
        for silenceMs in [0, 40, 80, 120, 160, 200, 300, 500, 1_000] {
            let samples = tone(afterMs: silenceMs)
            // вторая метка — как у модели: позже начала речи (здесь +300 мс)
            let onset = try XCTUnwrap(
                SpeechOnset.speechOnsetMs(samples: samples, secondTokenMs: silenceMs + 300), "тишина \(silenceMs) мс"
            )
            XCTAssertLessThanOrEqual(abs(onset - silenceMs), SpeechOnset.windowMs, "тишина \(silenceMs) мс")
        }
    }

    // Критерий 1: окно, в которое попал первый отсчёт тона, — ровно начало этого окна
    func testOnsetIsStartOfWindowContainingToneStart() {
        XCTAssertEqual(SpeechOnset.speechOnsetMs(samples: tone(afterMs: 130), secondTokenMs: nil), 120)
        XCTAssertEqual(SpeechOnset.speechOnsetMs(samples: tone(afterMs: 140), secondTokenMs: nil), 140)
    }

    // Критерий 1: кусок целиком тише 0,003 — nil
    func testChunkQuieterThanAbsoluteThresholdIsNil() {
        let quiet = tone(afterMs: 200, amplitude: 0.004) // RMS синуса = 0,004 / √2 ≈ 0,0028
        XCTAssertNil(SpeechOnset.speechOnsetMs(samples: quiet, secondTokenMs: nil))
        XCTAssertNil(SpeechOnset.speechOnsetMs(samples: [Float](repeating: 0, count: 16_000), secondTokenMs: nil))
        XCTAssertNil(SpeechOnset.speechOnsetMs(samples: [], secondTokenMs: nil))
    }

    // Критерий 1: фоновый шум 0,002 не срабатывает, тон срабатывает
    func testBackgroundNoiseDoesNotTriggerToneDoes() {
        let background = noise(rms: 0.002, count: 3 * rate)
        XCTAssertNil(SpeechOnset.speechOnsetMs(samples: background, secondTokenMs: nil))
        let speech = tone(afterMs: 500)
        let mixed = zip(background, speech).map { $0 + $1 }
        let onset = SpeechOnset.speechOnsetMs(samples: mixed, secondTokenMs: 900)
        XCTAssertEqual(onset, 500)
    }

    // Критерий 1: один токен — рассматривается весь кусок
    func testSingleTokenConsidersWholeChunk() {
        let samples = tone(afterMs: 2_500)
        XCTAssertEqual(SpeechOnset.speechOnsetMs(samples: samples, secondTokenMs: nil), 2_500)
        // с меткой второго токена раньше начала тона окон с сигналом нет
        XCTAssertNil(SpeechOnset.speechOnsetMs(samples: samples, secondTokenMs: 1_000))
    }

    // Критерий 1: речь с первого отсчёта, метка второго токена 40 мс — результат в 0…39
    func testSpeechFromFirstSampleWithSecondTokenAt40() throws {
        let onset = try XCTUnwrap(SpeechOnset.speechOnsetMs(samples: tone(afterMs: 0), secondTokenMs: 40))
        XCTAssertTrue((0...39).contains(onset), "\(onset)")
    }

    /// Результат строго меньше метки второго токена при любой её величине.
    func testOnsetStrictlyBeforeSecondToken() {
        let samples = tone(afterMs: 100)
        for second in [1, 19, 20, 21, 100, 101, 119, 120, 121] {
            if let onset = SpeechOnset.speechOnsetMs(samples: samples, secondTokenMs: second) {
                XCTAssertLessThan(onset, second, "вторая метка \(second)")
            }
        }
        XCTAssertNil(SpeechOnset.speechOnsetMs(samples: samples, secondTokenMs: 0))
        XCTAssertNil(SpeechOnset.speechOnsetMs(samples: samples, secondTokenMs: -40))
    }

    /// Порог — от наибольшего RMS до второй метки: громкая речь позже неё порог не поднимает.
    func testLoudnessAfterSecondTokenDoesNotRaiseThreshold() {
        var samples = tone(afterMs: 200, totalMs: 1_000, amplitude: 0.01)
        samples += tone(afterMs: 0, totalMs: 1_000, amplitude: 0.9)
        XCTAssertEqual(SpeechOnset.speechOnsetMs(samples: samples, secondTokenMs: 900), 200)
    }

    // Критерий 7: константы правила — static let модуля
    func testConstants() {
        XCTAssertEqual(SpeechOnset.windowMs, 20)
        XCTAssertEqual(SpeechOnset.absoluteThreshold, 0.003)
        XCTAssertEqual(SpeechOnset.relativeThreshold, 0.1)
        XCTAssertEqual(SpeechOnset.windowSamples, 320)
    }
}
