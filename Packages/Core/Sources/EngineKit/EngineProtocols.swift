//  TranscriptionEngine, DiarizationEngine, EmbeddingEngine, PostProcessor — C-011 v5 §4,
//  дословно. Инвариант 13: ни один сигнатурный тип не тянет CoreML/AVFoundation/XPC/ONNX —
//  протоколы и типы под ними собираются на Linux (Core (Linux), проверено сборкой этого
//  таргета в CI). Инвариант 14: `engineId` стабилен и попадает в `Transcript.engine`
//  дословно — обязанность реализации, не этого объявления.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)

import DomainCore

public protocol TranscriptionEngine: Sendable {
    var engineId: String { get }
    /// BCP-47; пустой массив — «любой» (движок не ограничивает список).
    func supportedLanguages() -> [String]
    func transcribe(
        _ request: TranscriptionRequest,
        progress: @Sendable @escaping (EngineProgress) -> Void
    ) async throws -> Transcript
}

public protocol DiarizationEngine: Sendable {
    var engineId: String { get }
    func diarize(
        _ request: DiarizationRequest,
        progress: @Sendable @escaping (EngineProgress) -> Void
    ) async throws -> DiarizationResult
}

public protocol EmbeddingEngine: Sendable {
    var engineId: String { get }
    var dimension: Int { get }
    var modelVersion: String { get }
    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResult
}

public protocol PostProcessor: Sendable {
    var engineId: String { get }
    func process(
        _ request: PostProcessRequest,
        progress: @Sendable @escaping (EngineProgress) -> Void
    ) async throws -> [MeetingOutputDraft]
}
