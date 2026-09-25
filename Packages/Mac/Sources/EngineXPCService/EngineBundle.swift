//  EngineBundle — четыре протокола движка (C-011 v5 §2), которые сторона сервиса вызывает.
//  Внедряются извне (инвариант композиции, не фейки, не синглтон): тесты подставляют
//  `EngineKit/Fakes`, прод — `Unavailable*Engine` этого же модуля (GigaAM/спайк R12 ещё не
//  реализован).
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (сторона сервиса NSXPCConnection)

import EngineKit

public struct EngineBundle: Sendable {
    public let transcription: TranscriptionEngine
    public let diarization: DiarizationEngine
    public let embedding: EmbeddingEngine
    public let postProcessor: PostProcessor

    public init(
        transcription: TranscriptionEngine, diarization: DiarizationEngine,
        embedding: EmbeddingEngine, postProcessor: PostProcessor
    ) {
        self.transcription = transcription
        self.diarization = diarization
        self.embedding = embedding
        self.postProcessor = postProcessor
    }
}
