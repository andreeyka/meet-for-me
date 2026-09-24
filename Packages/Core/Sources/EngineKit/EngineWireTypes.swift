//  EngineJobId, EngineRequest, EngineReply, EngineProgressMessage — C-012 v10 §2, дословно.
//  Ни одно поле здесь не числовое — синтезированный `Codable` (все вложенные значения сами
//  либо синтезируют его, либо несут собственный рукописный `init(from:)`) читает байты без
//  дополнительных ступеней (в)/(б) на этом уровне.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)

import DomainCore
import Foundation

public struct EngineJobId: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum EngineRequest: Codable, Equatable, Sendable {
    case transcribe(EngineJobId, TranscriptionRequest)
    case diarize(EngineJobId, DiarizationRequest)
    case embed(EngineJobId, EmbeddingRequest)
    case postProcess(EngineJobId, PostProcessRequest)
    case cancel(EngineJobId)
    case ping
}

public enum EngineReply: Codable, Equatable, Sendable {
    case transcript(EngineJobId, Transcript)
    case diarization(EngineJobId, DiarizationResult)
    case embedding(EngineJobId, EmbeddingResult)
    case outputs(EngineJobId, [MeetingOutputDraft])
    case cancelled(EngineJobId)
    case failed(EngineJobId, EngineError)
    case pong(serviceVersion: String, protocolVersion: Int)
}

public struct EngineProgressMessage: Codable, Equatable, Sendable {
    public let jobId: EngineJobId
    public let progress: EngineProgress

    public init(jobId: EngineJobId, progress: EngineProgress) {
        self.jobId = jobId
        self.progress = progress
    }
}
