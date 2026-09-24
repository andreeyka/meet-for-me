//  Общая оснастка тестов EngineKit: валидные значения C-011/C-012 для сборки входов и
//  `PlistSurgery` — текстовая правка одного значения в XML `PropertyList`, тот же приём,
//  что `BrokenWeights` (DomainCoreTests) для JSON: закодировать валидный эталон, заменить
//  ровно один литерал, декодировать обратно. Формат кодирования на границе — двоичный
//  (`EngineWire`), но `PropertyListDecoder` разбирает оба одинаково — формат XML взят здесь
//  только ради текстовой правки, не как формат провода.
//
//  Импорт без `@testable` (П8/п. 97 DomainCoreTests): `CodingKeys` и `EngineOwner` не видны
//  отсюда, поэтому непредставимые значения собираются только байтами, не внутренним путём.

import Foundation
import XCTest
import DomainCore
import EngineKit

enum EngineFixtures {
    static let recordingId = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    static let fileURL = URL(fileURLWithPath: "/tmp/meet-for-me/audio-mic.m4a")

    static func audioRef(
        channel: RecordingManifest.Channel = .mic,
        sampleRate: Int = 48_000,
        channelCount: Int = 1,
        offsetMs: Int = 0
    ) throws -> AudioRef {
        try AudioRef(
            recordingId: recordingId, channel: channel, fileURL: fileURL,
            sampleRate: sampleRate, channelCount: channelCount, offsetMs: offsetMs
        )
    }

    static func modelBundle(role: ModelRole = .asr) -> ModelBundle {
        ModelBundle(
            modelId: "fake-\(role.rawValue)", version: "1.0", role: role,
            runtime: .onnx, directoryURL: URL(fileURLWithPath: "/tmp/meet-for-me/models/\(role.rawValue)")
        )
    }

    static func transcriptionRequest(
        audio: [AudioRef]? = nil, language: String? = nil, wantWordTimestamps: Bool = false
    ) throws -> TranscriptionRequest {
        try TranscriptionRequest(
            audio: audio ?? [try audioRef()], language: language, wantWordTimestamps: wantWordTimestamps,
            asrModel: modelBundle(role: .asr), vadModel: nil
        )
    }

    static func diarizationRequest(
        channel: RecordingManifest.Channel = .system, expectedSpeakers: Int? = nil
    ) throws -> DiarizationRequest {
        try DiarizationRequest(
            audio: try audioRef(channel: channel), expectedSpeakers: expectedSpeakers,
            segmentationModel: modelBundle(role: .diarization), embeddingModel: modelBundle(role: .embedding)
        )
    }

    static func embeddingRequest(startMs: Int = 0, endMs: Int = 500) throws -> EmbeddingRequest {
        let slice = try AudioSlice(source: try audioRef(), startMs: startMs, endMs: endMs)
        return try EmbeddingRequest(slice: slice, model: modelBundle(role: .embedding))
    }

    static func postProcessRequest(transcript: Transcript) throws -> PostProcessRequest {
        try PostProcessRequest(
            transcript: transcript, meetingTitle: nil, attendeeNames: [],
            agendaText: nil, profileId: "profile-1", model: nil
        )
    }
}

/// Ошибка при попытке доказать нарушение, которое обязано выйти именно на этой ступени
/// (в) — не (б): цель замены не найдена в эталоне, либо не-UTF8 после правки.
enum PlistSurgeryError: Error {
    case targetNotFound(String)
    case notUTF8
}

/// Достигается, только если проверяемый throwing-init контракта перестал бросать на
/// заведомо непредставимом/невалидном входе — сам факт того, что тест дошёл сюда, уже
/// провал (см. `XCTFail` рядом с каждым местом, где эта ошибка брошена).
enum EngineTestSupportError: Error {
    case unreachable
}

/// Текстовая правка одного значения в XML `PropertyList` — способ дать декодеру байты,
/// каких throwing-init самого типа никогда бы не выпустил (К15, К32, К40(i)).
enum PlistSurgery {
    static func data<T: Encodable>(for value: T, replacing target: String, with replacement: String) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let xml = try encoder.encode(value)
        guard let text = String(data: xml, encoding: .utf8) else { throw PlistSurgeryError.notUTF8 }
        guard text.contains(target) else { throw PlistSurgeryError.targetNotFound(target) }
        let mutated = text.replacingOccurrences(of: target, with: replacement)
        guard let mutatedData = mutated.data(using: .utf8) else { throw PlistSurgeryError.notUTF8 }
        return mutatedData
    }
}

/// Собирает `EngineProgress` из `@Sendable`-замыкания прогресса: простой `var`,
/// захваченный такой закрытием, компилятор не может статически доказать
/// непересекающимся ("mutation of captured var in concurrently-executing code").
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [EngineProgress] = []

    func append(_ item: EngineProgress) {
        lock.lock(); items.append(item); lock.unlock()
    }

    var all: [EngineProgress] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// `EngineError`/`DomainValidationError` не сравниваются напрямую в проверках ниже —
/// сравнение по структурным полям, как того требует К2 дословно.
func assertInvalidResult(
    _ error: Error, invariant: Int, type: String, path: String, contract: String? = nil,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard case EngineError.invalidResult(let validation) = error else {
        XCTFail("ожидался .invalidResult, получено \(error)", file: file, line: line)
        return
    }
    XCTAssertEqual(validation.invariant, invariant, "invariant", file: file, line: line)
    XCTAssertEqual(validation.type, type, "type", file: file, line: line)
    XCTAssertEqual(validation.path, path, "path", file: file, line: line)
    if let contract {
        XCTAssertEqual(validation.contract, contract, "contract", file: file, line: line)
    }
}
