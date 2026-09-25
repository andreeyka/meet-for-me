//  UnavailableTranscriptionEngine, UnavailableDiarizationEngine, UnavailableEmbeddingEngine,
//  UnavailablePostProcessor — заглушки для прода на время, пока GigaAM (спайк R12) не
//  реализован (`Packages/Core/Sources/GigaAM/GigaAM.swift` — пустой каркас).
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (сторона сервиса NSXPCConnection)
//
//  РАСКРЫТИЕ (ни C-011, ни C-012, ни MEE-370 не называют это соглашение — решение этой
//  задачи, не вычитанный контрактный текст): каждая заглушка честно отказывает
//  `EngineError.modelMissing(modelId:, version:)`, называя ИМЕННО ту модель, что просил
//  запрос, — а не подделывает результат фиктивным транскриптом/эмбеддингом. Это буквально
//  верно (движка, который умеет эту модель, сегодня нет ни для одной модели) и укладывается
//  в уже описанный С-011 случай «модель недоступна», не требуя нового кода ошибки. У
//  `PostProcessRequest.model` (в отличие от трёх других запросов) `ModelBundle` НЕОБЯЗАТЕЛЕН —
//  `nil` означает «облачная реализация, своей модели нет» (комментарий `EngineRequests.swift`);
//  назвать несуществующую модель в этом случае нечем, поэтому у `PostProcessor` вместо
//  `.modelMissing` — `.runtimeFailure(message:)` с тем же честным «движок недоступен».

import DomainCore
import EngineKit

public final class UnavailableTranscriptionEngine: TranscriptionEngine, Sendable {
    public let engineId = "unavailable-transcription"
    public init() {}

    public func supportedLanguages() -> [String] { [] }

    public func transcribe(
        _ request: TranscriptionRequest, progress: @Sendable @escaping (EngineProgress) -> Void
    ) async throws -> Transcript {
        throw EngineError.modelMissing(modelId: request.asrModel.modelId, version: request.asrModel.version)
    }
}

public final class UnavailableDiarizationEngine: DiarizationEngine, Sendable {
    public let engineId = "unavailable-diarization"
    public init() {}

    public func diarize(
        _ request: DiarizationRequest, progress: @Sendable @escaping (EngineProgress) -> Void
    ) async throws -> DiarizationResult {
        throw EngineError.modelMissing(
            modelId: request.segmentationModel.modelId, version: request.segmentationModel.version
        )
    }
}

public final class UnavailableEmbeddingEngine: EmbeddingEngine, Sendable {
    public let engineId = "unavailable-embedding"
    public let dimension = 0
    public let modelVersion = "unavailable"
    public init() {}

    public func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResult {
        throw EngineError.modelMissing(modelId: request.model.modelId, version: request.model.version)
    }
}

public final class UnavailablePostProcessor: PostProcessor, Sendable {
    public let engineId = "unavailable-post-process"
    public init() {}

    public func process(
        _ request: PostProcessRequest, progress: @Sendable @escaping (EngineProgress) -> Void
    ) async throws -> [MeetingOutputDraft] {
        if let model = request.model {
            throw EngineError.modelMissing(modelId: model.modelId, version: model.version)
        }
        throw EngineError.runtimeFailure(message: "движок недоступен: постобработка ещё не реализована (GigaAM)")
    }
}
