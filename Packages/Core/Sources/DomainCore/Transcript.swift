//  Transcript — DTO и формат файла `transcript.v<N>.json` контракта C-003.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Мусор реального движка отвергается, а не чинится: слово с `confidence == 1.0000001`
//  и сегмент нулевой длины — это отказ на весь транскрипт, и это принятое решение.

import Foundation

/// Расшифровка записи на общей шкале обоих каналов.
public struct Transcript: Codable, Equatable, Sendable, DomainValidatable {

    /// Версия схемы файла, которую пишет и принимает этот код.
    public static let currentSchemaVersion: Int = 2

    public let schemaVersion: Int
    public let recordingId: UUID
    /// BCP-47: форма, а не реестр IANA.
    public let language: String
    public let engine: String
    public let modelVersion: String
    public let createdAt: Date
    public let segments: [Segment]
    public let speakers: [Speaker]

    public init(
        schemaVersion: Int = Transcript.currentSchemaVersion,
        recordingId: UUID,
        language: String,
        engine: String,
        modelVersion: String,
        createdAt: Date,
        segments: [Segment],
        speakers: [Speaker]
    ) throws {
        self.schemaVersion = schemaVersion
        self.recordingId = recordingId
        self.language = language
        self.engine = engine
        self.modelVersion = modelVersion
        self.createdAt = createdAt
        self.segments = segments
        self.speakers = speakers
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, recordingId, language, engine, modelVersion, createdAt
        case segments, speakers
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decodeBounded(Int.self, forKey: .schemaVersion)
        recordingId = try box.decode(UUID.self, forKey: .recordingId)
        language = try box.decode(String.self, forKey: .language)
        engine = try box.decode(String.self, forKey: .engine)
        modelVersion = try box.decode(String.self, forKey: .modelVersion)
        createdAt = try box.decode(Date.self, forKey: .createdAt)
        segments = try box.decode([Segment].self, forKey: .segments)
        speakers = try box.decode([Speaker].self, forKey: .speakers)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(schemaVersion, forKey: .schemaVersion)
        try box.encode(recordingId, forKey: .recordingId)
        try box.encode(language, forKey: .language)
        try box.encode(engine, forKey: .engine)
        try box.encode(modelVersion, forKey: .modelVersion)
        try box.encode(createdAt, forKey: .createdAt)
        try box.encode(segments, forKey: .segments)
        try box.encode(speakers, forKey: .speakers)
    }

    /// Ступени §0.2 п. 6: (а) вложенные значения → (в) представимость → (б) собственные
    /// инварианты в порядке номеров. Инвариант 2 ответа не даёт ни на одном входе: он говорит,
    /// чем является величина, а не какой она обязана быть.
    public func validate() throws {
        let owner = DomainOwner(contract: "C-003", type: "Transcript")
        for segment in segments {
            try segment.validate()
        }
        for speaker in speakers {
            try speaker.validate()
        }
        try owner.requireInt(schemaVersion, "schemaVersion")
        try owner.requireDate(createdAt, "createdAt")
        try owner.check(schemaVersion == Transcript.currentSchemaVersion, 1, "schemaVersion",
                        "файл схемы \(schemaVersion), этот код принимает "
                        + "\(Transcript.currentSchemaVersion)")
        try validateSegmentOrder(owner)
        try validateClusters(owner)
        try validateEmbeddingLengths(owner)
        try owner.check(Transcript.isBCP47Shaped(language), 13, "language",
                        "не форма BCP-47: \(language)")
        try validateChannelOverlap(owner)
    }

    /// Инвариант 3 в части сортировки: по неубыванию `startMs`; взаимный порядок равных — данные.
    private func validateSegmentOrder(_ owner: DomainOwner) throws {
        for position in segments.indices.dropFirst()
        where segments[position].startMs < segments[position - 1].startMs {
            throw owner.fail(3, "segments[\(position)].startMs", "сегменты не отсортированы по неубыванию")
        }
    }

    /// Инвариант 9: уникальность `cluster` проверяет транскрипт (нарушителем является пара),
    /// присутствие кластера — тоже он, потому что сегменту проверить это нечем.
    private func validateClusters(_ owner: DomainOwner) throws {
        var clusters = Set<Int>()
        for speaker in speakers where !clusters.insert(speaker.cluster).inserted {
            throw owner.fail(9, "speakers", "cluster \(speaker.cluster) встречается дважды")
        }
        for (position, segment) in segments.enumerated() {
            guard let cluster = segment.speakerCluster else { continue }
            guard clusters.contains(cluster) else {
                throw owner.fail(9, "segments[\(position)].speakerCluster",
                                 "кластера \(cluster) нет в speakers")
            }
        }
    }

    /// Инвариант 11. Длина берётся полем массива — нового прохода по элементам здесь нет.
    private func validateEmbeddingLengths(_ owner: DomainOwner) throws {
        var lengths: [String: Int] = [:]
        for speaker in speakers {
            guard let embedding = speaker.embedding,
                  let version = speaker.embeddingModelVersion else { continue }
            if let known = lengths[version], known != embedding.count {
                throw owner.fail(11, "speakers", "эмбеддинги модели \(version) разной длины")
            }
            lengths[version] = embedding.count
        }
    }

    /// Инвариант 14: сегменты разных каналов вправе перекрываться, одного — нет.
    /// Предшественник берётся внутри подпоследовательности канала, индекс — в полной коллекции.
    private func validateChannelOverlap(_ owner: DomainOwner) throws {
        var lastEnd: [RecordingManifest.Channel: Int] = [:]
        for (position, segment) in segments.enumerated() {
            if let previousEnd = lastEnd[segment.channel], segment.startMs < previousEnd {
                throw owner.fail(14, "segments[\(position)].startMs",
                                 "сегменты канала \(segment.channel.rawValue) перекрываются")
            }
            lastEnd[segment.channel] = segment.endMs
        }
    }

    /// Инвариант 13: `^[a-z]{2,3}(-[A-Za-z0-9]{1,8})*$`.
    static func isBCP47Shaped(_ language: String) -> Bool {
        let parts = language.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = parts.first, (2...3).contains(primary.count) else { return false }
        guard primary.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return false }
        for subtag in parts.dropFirst() {
            guard (1...8).contains(subtag.count) else { return false }
            guard subtag.allSatisfy(Transcript.isAlphanumericASCII) else { return false }
        }
        return true
    }

    private static func isAlphanumericASCII(_ symbol: Character) -> Bool {
        (symbol >= "a" && symbol <= "z") || (symbol >= "A" && symbol <= "Z")
            || (symbol >= "0" && symbol <= "9")
    }
}
