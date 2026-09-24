//  TranscriptionRequest, DiarizationRequest, EmbeddingRequest, PostProcessRequest —
//  C-011 v5 «Определение» §2: вход каждого из четырёх протоколов движка.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)

import DomainCore
import Foundation

/// Вход `TranscriptionEngine.transcribe`. Инвариант 2: все `audio` — один `recordingId`,
/// иначе `EngineError.unsupportedRequest` (проверяет реализация протокола, не этот тип).
public struct TranscriptionRequest: Codable, Equatable, Sendable, DomainValidatable {
    public let audio: [AudioRef]
    /// BCP-47; `nil` — движок определяет язык сам.
    public let language: String?
    public let wantWordTimestamps: Bool
    public let asrModel: ModelBundle
    public let vadModel: ModelBundle?

    public init(
        audio: [AudioRef], language: String?, wantWordTimestamps: Bool,
        asrModel: ModelBundle, vadModel: ModelBundle?
    ) throws {
        self.audio = audio
        self.language = language
        self.wantWordTimestamps = wantWordTimestamps
        self.asrModel = asrModel
        self.vadModel = vadModel
        try validate()
    }

    public func validate() throws {
        for ref in audio { try ref.validate() }
    }
}

/// Вход `DiarizationEngine.diarize`. Инвариант 5 (только `.system`) — реализация протокола
/// решает во время исполнения, не эта форма.
public struct DiarizationRequest: Codable, Equatable, Sendable, DomainValidatable {
    public let audio: AudioRef
    public let expectedSpeakers: Int?
    public let segmentationModel: ModelBundle
    public let embeddingModel: ModelBundle

    public init(
        audio: AudioRef, expectedSpeakers: Int?,
        segmentationModel: ModelBundle, embeddingModel: ModelBundle
    ) throws {
        self.audio = audio
        self.expectedSpeakers = expectedSpeakers
        self.segmentationModel = segmentationModel
        self.embeddingModel = embeddingModel
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case audio, expectedSpeakers, segmentationModel, embeddingModel
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        audio = try box.decode(AudioRef.self, forKey: .audio)
        expectedSpeakers = try box.decodeBoundedIfPresent(Int.self, forKey: .expectedSpeakers)
        segmentationModel = try box.decode(ModelBundle.self, forKey: .segmentationModel)
        embeddingModel = try box.decode(ModelBundle.self, forKey: .embeddingModel)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(audio, forKey: .audio)
        try box.encodeIfPresent(expectedSpeakers, forKey: .expectedSpeakers)
        try box.encode(segmentationModel, forKey: .segmentationModel)
        try box.encode(embeddingModel, forKey: .embeddingModel)
    }

    public func validate() throws {
        try audio.validate()
        let owner = EngineOwner(contract: "C-011", type: "DiarizationRequest")
        try owner.requireInt(expectedSpeakers, "expectedSpeakers")
    }
}

/// Вход `EmbeddingEngine.embed`.
public struct EmbeddingRequest: Codable, Equatable, Sendable, DomainValidatable {
    public let slice: AudioSlice
    public let model: ModelBundle

    public init(slice: AudioSlice, model: ModelBundle) throws {
        self.slice = slice
        self.model = model
        try validate()
    }

    public func validate() throws {
        try slice.validate()
    }
}

/// Вход `PostProcessor.process`. `model == nil` — облачная реализация, своей модели нет.
public struct PostProcessRequest: Codable, Equatable, Sendable, DomainValidatable {
    public let transcript: Transcript
    public let meetingTitle: String?
    public let attendeeNames: [String]
    public let agendaText: String?
    public let profileId: String
    public let model: ModelBundle?

    public init(
        transcript: Transcript, meetingTitle: String?, attendeeNames: [String],
        agendaText: String?, profileId: String, model: ModelBundle?
    ) throws {
        self.transcript = transcript
        self.meetingTitle = meetingTitle
        self.attendeeNames = attendeeNames
        self.agendaText = agendaText
        self.profileId = profileId
        self.model = model
        try validate()
    }

    public func validate() throws {
        try transcript.validate()
    }
}
