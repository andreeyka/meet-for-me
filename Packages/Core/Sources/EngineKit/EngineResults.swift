//  DiarizationResult (+ Turn), EmbeddingResult — C-011 v5 «Определение» §3: выход
//  `DiarizationEngine`/`EmbeddingEngine`. Инварианты 6-9 (сортировка реплик, биекция
//  cluster↔speakers, длина vector == dimension) — НЕ проверяются здесь: §0 «ступень (б)»
//  для них пуста, проверка на фейке была бы циклической (реализатор — сам фейк движка).
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)

import DomainCore

/// Выход `DiarizationEngine.diarize`.
public struct DiarizationResult: Codable, Equatable, Sendable, DomainValidatable {

    /// Одна реплика: позиция на шкале записи и кластер (не имя человека — присвоение имени
    /// кластеру внешнее, C-011 самого типа не касается).
    public struct Turn: Codable, Equatable, Sendable, DomainValidatable {
        public let startMs: Int
        public let endMs: Int
        public let cluster: Int

        public init(startMs: Int, endMs: Int, cluster: Int) throws {
            self.startMs = startMs
            self.endMs = endMs
            self.cluster = cluster
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            startMs = try box.decodeBounded(Int.self, forKey: .startMs)
            endMs = try box.decodeBounded(Int.self, forKey: .endMs)
            cluster = try box.decodeBounded(Int.self, forKey: .cluster)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(startMs, forKey: .startMs)
            try box.encode(endMs, forKey: .endMs)
            try box.encode(cluster, forKey: .cluster)
        }

        public func validate() throws {
            let owner = EngineOwner(contract: "C-011", type: "DiarizationResult.Turn")
            try owner.requireInt(startMs, "startMs")
            try owner.requireInt(endMs, "endMs")
            try owner.requireInt(cluster, "cluster")
        }
    }

    public let turns: [Turn]
    public let speakers: [Transcript.Speaker]
    public let modelVersion: String

    public init(turns: [Turn], speakers: [Transcript.Speaker], modelVersion: String) throws {
        self.turns = turns
        self.speakers = speakers
        self.modelVersion = modelVersion
        try validate()
    }

    public func validate() throws {
        for turn in turns { try turn.validate() }
        for speaker in speakers { try speaker.validate() }
    }
}

/// Вынесено из тела `Turn` тем же приёмом, что `TranscriptNested.swift` (DomainCore) для
/// `Transcript.Word`/`Segment`/`Speaker`: `CodingKeys`, объявленный ВНУТРИ `Turn`, стоял бы
/// вторым уровнем вложенности (`DiarizationResult.Turn.CodingKeys`) — правило SwiftLint
/// `nesting` (--strict) держит предел в один уровень, а сам `Turn` — уже первый уровень,
/// названный контрактом (C-011 v5 §3), не мой выбор.
extension DiarizationResult.Turn {
    enum CodingKeys: String, CodingKey {
        case startMs, endMs, cluster
    }
}

/// Выход `EmbeddingEngine.embed`.
public struct EmbeddingResult: Codable, Equatable, Sendable, DomainValidatable {
    public let vector: [Float]
    public let dimension: Int
    public let modelVersion: String

    public init(vector: [Float], dimension: Int, modelVersion: String) throws {
        self.vector = vector
        self.dimension = dimension
        self.modelVersion = modelVersion
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case vector, dimension, modelVersion
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        vector = try box.decodeFinite([Float].self, forKey: .vector)
        dimension = try box.decodeBounded(Int.self, forKey: .dimension)
        modelVersion = try box.decode(String.self, forKey: .modelVersion)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(vector, forKey: .vector)
        try box.encode(dimension, forKey: .dimension)
        try box.encode(modelVersion, forKey: .modelVersion)
    }

    public func validate() throws {
        let owner = EngineOwner(contract: "C-011", type: "EmbeddingResult")
        try owner.requireFiniteElements(vector, "vector")
        try owner.requireInt(dimension, "dimension")
    }
}
