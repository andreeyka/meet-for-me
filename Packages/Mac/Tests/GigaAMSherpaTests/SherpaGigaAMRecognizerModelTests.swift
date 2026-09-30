//  SherpaGigaAMRecognizerModelTests — MEE-503 (Z5, MEE-486): критерии 2 и 3 на настоящей модели.
//
//  Модуль: gigaam · Владелец: DEV-2
//
//  Включается переменной `GIGAAM_MODEL_DIR` — каталог с `model.int8.onnx` и `tokens.txt`
//  (GigaAM v3 e2e_ctc int8); без неё — `XCTSkip`: модель лежит только на Mac РП, в CI её нет.
//  Распознавание дополнительно требует `GIGAAM_TEST_WAV` — 16 кГц моно, 17 с, `say -v Milena`
//  с пятью предложениями `expectedSentences` (тот же текст, что у стенда R12, MEE-426), вне репозитория.

import AVFoundation
import Foundation
import GigaAM
@testable import GigaAMSherpa
import XCTest

final class SherpaGigaAMRecognizerModelTests: XCTestCase {

    /// Текст записи стенда R12 (MEE-426): пять предложений.
    static let expectedSentences = [
        "Добрый день, коллеги.",
        "Сегодня мы обсуждаем план выпуска новой версии приложения.",
        "Первая сборка для тестирования будет готова в пятницу.",
        "Нам нужно проверить распознавание речи на длинных встречах.",
        "Если вопросов нет, давайте перейдём к следующему пункту повестки."
    ]

    /// Критерий 3: загрузка модели не дольше 1,5 с (R12: 0,28–0,32 с, холодный старт ~1,1 с).
    static let maxLoadSeconds = 1.5
    static let frameSeconds = 0.04

    private func modelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["GIGAAM_MODEL_DIR"], !path.isEmpty else {
            throw XCTSkip("GIGAAM_MODEL_DIR не задана — тест с моделью только на Mac РП")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func testWav() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["GIGAAM_TEST_WAV"], !path.isEmpty else {
            throw XCTSkip("GIGAAM_TEST_WAV не задана")
        }
        return URL(fileURLWithPath: path)
    }

    // Критерий 3
    func testModelLoadsWithinLimit() throws {
        let directory = try modelDirectory()
        let start = Date()
        _ = try SherpaGigaAMRecognizerFactory().makeRecognizer(modelDirectory: directory)
        let seconds = Date().timeIntervalSince(start)
        print(String(format: "GigaAMSherpa: загрузка модели %.3f с", seconds))
        XCTAssertLessThanOrEqual(seconds, Self.maxLoadSeconds)
    }

    // Критерий 2
    func testSeventeenSecondsGiveFiveSentencesWithFrameTimestamps() throws {
        let directory = try modelDirectory()
        let samples = try Self.loadMono16k(try testWav())
        XCTAssertEqual(Double(samples.count) / 16_000, 17, accuracy: 0.5, "запись должна быть ~17 с")

        let recognizer = try SherpaGigaAMRecognizerFactory().makeRecognizer(modelDirectory: directory)
        let start = Date()
        let chunk = try recognizer.recognize(samples: samples)
        let seconds = Date().timeIntervalSince(start)
        print("GigaAMSherpa: текст: \(chunk.text)")
        print(String(format: "GigaAMSherpa: распознавание %.3f с, токенов %d", seconds, chunk.tokens.count))

        let sentences = Self.sentences(chunk.text)
        XCTAssertEqual(sentences.count, 5, "\(sentences)")
        XCTAssertEqual(sentences.map(Self.normalized), Self.expectedSentences.map(Self.normalized))

        XCTAssertFalse(chunk.tokens.isEmpty)
        XCTAssertEqual(chunk.tokens.count, chunk.timestamps.count)
        for (earlier, later) in zip(chunk.timestamps, chunk.timestamps.dropFirst()) {
            XCTAssertGreaterThan(later, earlier, "метки должны строго возрастать")
        }
        for stamp in chunk.timestamps {
            let frames = stamp / Self.frameSeconds
            XCTAssertEqual(frames, frames.rounded(), accuracy: 1e-3, "метка \(stamp) с не на сетке 40 мс")
            XCTAssertGreaterThanOrEqual(stamp, 0)
        }
        // Порт: начало слова — `▁`, пробела в токенах нет; склейка токенов — это текст.
        XCTAssertFalse(chunk.tokens.contains { $0.contains(" ") })
        XCTAssertTrue(chunk.tokens.first?.hasPrefix("▁") ?? false)
        let joined = chunk.tokens.joined().replacingOccurrences(of: "▁", with: " ")
        XCTAssertEqual(
            joined.trimmingCharacters(in: .whitespaces), chunk.text.trimmingCharacters(in: .whitespaces)
        )
    }

    func testChunkLongerThanThirtySecondsIsRejected() throws {
        let recognizer = try SherpaGigaAMRecognizerFactory().makeRecognizer(modelDirectory: try modelDirectory())
        XCTAssertThrowsError(try recognizer.recognize(samples: [Float](repeating: 0, count: 30 * 16_000 + 1))) {
            guard case .runtimeFailure = $0 as? GigaAMRecognizerError else { return XCTFail("\($0)") }
        }
    }

    func testSilenceGivesEmptyChunk() throws {
        let recognizer = try SherpaGigaAMRecognizerFactory().makeRecognizer(modelDirectory: try modelDirectory())
        let chunk = try recognizer.recognize(samples: [Float](repeating: 0, count: 16_000))
        XCTAssertEqual(chunk.tokens.count, chunk.timestamps.count)
        XCTAssertTrue(chunk.text.trimmingCharacters(in: .whitespaces).isEmpty, chunk.text)
    }

    // MARK: - Помощники

    /// Предложения — куски текста до `.`, `?`, `!`, `…` включительно; хвост без знака — тоже предложение
    /// (CTC может потерять финальную точку — R12).
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".?!…".contains(character) {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// Сравнение без регистра, пунктуации и различия «е/ё».
    static func normalized(_ sentence: String) -> String {
        sentence.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
            .map(String.init).joined()
            .split(separator: " ").joined(separator: " ")
    }

    static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1 else {
            throw XCTSkip("GIGAAM_TEST_WAV: нужен 16 кГц моно, а не \(format)")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("GIGAAM_TEST_WAV: буфер не выделен")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { throw XCTSkip("GIGAAM_TEST_WAV: не Float32") }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
