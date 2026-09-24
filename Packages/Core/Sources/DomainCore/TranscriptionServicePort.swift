//  TranscriptionServicePort — контракт C-012 (MEE-20) v9, §1 «Доменный порт (DomainCore)»,
//  дословно: «транскрибируй запись X по профилю Y»; о XPC и о движках порт не знает ничего.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Реализация — `Packages/Mac/Sources/EngineXPCClient/` (engine-xpc, часть 2 MEE-390, ещё не
//  заведена): адаптер обращается к каталогу моделей (C-014), собирает `TranscriptionRequest`
//  (C-011) и говорит с сервисом через `EngineRequest`/`EngineReply` (`EngineKit`) поверх
//  `NSXPCConnection`. Этот файл несёт только §1 — сам провод (`EngineJobId`/`EngineRequest`/
//  `EngineReply`/`EngineWire`) и коды транспортных отказов (§3.1) объявлены в `EngineKit`,
//  не здесь (C-012 §0, таблица трёх слоёв).
//
//  Порядок типов и порядок полей — дословно по §1.

import Foundation

public struct TranscriptionJobSpec: Codable, Equatable, Sendable {
    public let recordingId: UUID
    public let profileId: String        // профиль транскрибации (C-014)
    public let language: String?        // BCP-47; nil — по профилю
    public let wantWordTimestamps: Bool
    public let diarizeSystemChannel: Bool

    public init(
        recordingId: UUID,
        profileId: String,
        language: String?,
        wantWordTimestamps: Bool,
        diarizeSystemChannel: Bool
    ) {
        self.recordingId = recordingId
        self.profileId = profileId
        self.language = language
        self.wantWordTimestamps = wantWordTimestamps
        self.diarizeSystemChannel = diarizeSystemChannel
    }
}

public struct TranscriptionProgress: Codable, Equatable, Sendable {
    public let stage: String            // rawValue EngineStage (C-011)
    public let fraction: Double         // 0...1 внутри этапа

    public init(stage: String, fraction: Double) {
        self.stage = stage
        self.fraction = fraction
    }
}

public enum TranscriptionServiceError: Error, Codable, Equatable, Sendable {
    case serviceUnavailable(message: String)
    case serviceCrashed
    case protocolVersionMismatch(client: Int, service: Int)
    case messageTooLarge(bytes: Int)

    /// Сервис жив и ответил, но запрос не принял: не разобрал байты либо
    /// разобрал и получил значение, нарушающее инвариант (§3, §3.2).
    case invalidRequest(message: String)

    /// Модели профиля не готовы в момент обращения к движку: `resolve(profileId:)`
    /// или `beginUse(_:)` каталога моделей (C-014) отказали до отправки запроса.
    case modelsNotReady(profileId: String, message: String)

    case timedOut(seconds: Int)
    case engineFailure(code: String, message: String)   // EngineError (C-011), сведённая к коду и тексту
    case cancelled
}

public protocol TranscriptionServicePort: Sendable {
    func transcribe(
        _ spec: TranscriptionJobSpec,
        progress: @Sendable @escaping (TranscriptionProgress) -> Void
    ) async throws -> Transcript

    func embed(recordingId: UUID, startMs: Int, endMs: Int, profileId: String) async throws -> [Float]

    func ping() async throws -> String   // версия сервиса
}
