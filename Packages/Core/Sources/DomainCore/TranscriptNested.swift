//  Вложенные типы C-003: Word, Segment, Speaker.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Асимметрия умышленна: `word.endMs == word.startMs` разрешено, `segment.endMs == segment.startMs`
//  запрещено. Сегмент нулевой длины не содержит ничего, а нулевая ширина слова законна —
//  CTC-декодер выдаёт такую позицию для схлопнувшегося токена и для знака препинания.

import Foundation

extension Transcript {

    /// Слово с позицией на шкале записи.
    public struct Word: Codable, Equatable, Sendable, DomainValidatable {
        public let startMs: Int
        public let endMs: Int
        public let text: String
        /// `0...1`; `nil`, если движок уверенность не отдаёт.
        public let confidence: Double?
        /// Слово до автоматической постправки именами; `nil`, если не правилось.
        public let original: String?

        public init(startMs: Int, endMs: Int, text: String,
                    confidence: Double?, original: String?) throws {
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
            self.confidence = confidence
            self.original = original
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            startMs = try box.decodeBounded(Int.self, forKey: .startMs)
            endMs = try box.decodeBounded(Int.self, forKey: .endMs)
            text = try box.decode(String.self, forKey: .text)
            confidence = try box.decodeFiniteIfPresent(Double.self, forKey: .confidence)
            original = try box.decodeIfPresent(String.self, forKey: .original)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(startMs, forKey: .startMs)
            try box.encode(endMs, forKey: .endMs)
            try box.encode(text, forKey: .text)
            try box.encodeIfPresent(confidence, forKey: .confidence)
            try box.encodeIfPresent(original, forKey: .original)
        }

        public func validate() throws {
            let owner = DomainOwner(contract: "C-003", type: "Transcript.Word")
            try owner.requireInt(startMs, "startMs")
            try owner.requireInt(endMs, "endMs")
            try owner.requireFinite(confidence, "confidence")
            try owner.check(endMs >= startMs, 4, "endMs", "слово отрицательной длительности")
            guard let confidence else { return }
            try owner.check((0.0...1.0).contains(confidence), 7, "confidence",
                            "уверенность вне 0...1: \(confidence)")
        }
    }

    /// Реплика одного канала.
    public struct Segment: Codable, Equatable, Sendable, DomainValidatable {
        public let startMs: Int
        public let endMs: Int
        public let channel: RecordingManifest.Channel
        /// Кластер диаризации; `nil` для канала `mic`.
        public let speakerCluster: Int?
        public let text: String
        /// Текст до автоматических замен; `nil`, если не правился.
        public let textOriginal: String?
        /// Минимум по уверенностям слов, не среднее.
        public let textConfidence: Double?
        public let words: [Word]

        public init(startMs: Int, endMs: Int, channel: RecordingManifest.Channel,
                    speakerCluster: Int?, text: String, textOriginal: String?,
                    textConfidence: Double?, words: [Word]) throws {
            self.startMs = startMs
            self.endMs = endMs
            self.channel = channel
            self.speakerCluster = speakerCluster
            self.text = text
            self.textOriginal = textOriginal
            self.textConfidence = textConfidence
            self.words = words
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            startMs = try box.decodeBounded(Int.self, forKey: .startMs)
            endMs = try box.decodeBounded(Int.self, forKey: .endMs)
            channel = try box.decode(RecordingManifest.Channel.self, forKey: .channel)
            speakerCluster = try box.decodeBoundedIfPresent(Int.self, forKey: .speakerCluster)
            text = try box.decode(String.self, forKey: .text)
            textOriginal = try box.decodeIfPresent(String.self, forKey: .textOriginal)
            textConfidence = try box.decodeFiniteIfPresent(Double.self, forKey: .textConfidence)
            words = try box.decode([Word].self, forKey: .words)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(startMs, forKey: .startMs)
            try box.encode(endMs, forKey: .endMs)
            try box.encode(channel, forKey: .channel)
            try box.encodeIfPresent(speakerCluster, forKey: .speakerCluster)
            try box.encode(text, forKey: .text)
            try box.encodeIfPresent(textOriginal, forKey: .textOriginal)
            try box.encodeIfPresent(textConfidence, forKey: .textConfidence)
            try box.encode(words, forKey: .words)
        }

        public func validate() throws {
            let owner = DomainOwner(contract: "C-003", type: "Transcript.Segment")
            for word in words {
                try word.validate()
            }
            try owner.requireInt(startMs, "startMs")
            try owner.requireInt(endMs, "endMs")
            try owner.requireInt(speakerCluster, "speakerCluster")
            try owner.requireFinite(textConfidence, "textConfidence")
            try owner.check(endMs > startMs, 3, "endMs", "сегмент нулевой или отрицательной длины")
            try owner.check(startMs >= 0, 3, "startMs", "startMs отрицателен")
            try validateWordBounds(owner)
            try validateCluster(owner)
            try validateConfidence(owner)
            try owner.check((speakerCluster ?? 0) >= 0, 9, "speakerCluster", "кластер отрицателен")
        }

        /// Инвариант 4 в части порядка слов и границ: коллекция обходится один раз,
        /// на каждом элементе проверяются все утверждения этого инварианта.
        private func validateWordBounds(_ owner: DomainOwner) throws {
            var previousStart: Int?
            for (position, word) in words.enumerated() {
                if let previous = previousStart, word.startMs < previous {
                    throw owner.fail(4, "words[\(position)].startMs", "слова не отсортированы")
                }
                guard word.startMs >= startMs else {
                    throw owner.fail(4, "words[\(position)].startMs", "слово начинается раньше сегмента")
                }
                guard word.endMs <= endMs else {
                    throw owner.fail(4, "words[\(position)].endMs", "слово кончается позже сегмента")
                }
                previousStart = word.startMs
            }
        }

        /// Инварианты 5 и 6. Содержательный текст определён обрезкой пробельных символов.
        private func validateCluster(_ owner: DomainOwner) throws {
            if channel == .mic {
                try owner.check(speakerCluster == nil, 5, "speakerCluster",
                                "микрофонный канал кластера не несёт")
            }
            guard channel == .system else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try owner.check(speakerCluster != nil, 6, "speakerCluster",
                            "содержательный текст на системном канале без кластера")
        }

        /// Инварианты 7 и 8. При пустом `words` или хотя бы одном `confidence == nil`
        /// инвариант 8 не применяется.
        private func validateConfidence(_ owner: DomainOwner) throws {
            if let textConfidence {
                try owner.check((0.0...1.0).contains(textConfidence), 7, "textConfidence",
                                "уверенность вне 0...1: \(textConfidence)")
            }
            guard !words.isEmpty else { return }
            var minimum = Double.infinity
            for word in words {
                guard let value = word.confidence else { return }
                minimum = Swift.min(minimum, value)
            }
            try owner.check(textConfidence == minimum, 8, "textConfidence",
                            "textConfidence не равен минимуму по словам")
        }
    }

    /// Кластер диаризации.
    public struct Speaker: Codable, Equatable, Sendable, DomainValidatable {
        public let cluster: Int
        /// Голосовой эмбеддинг кластера.
        public let embedding: [Float]?
        public let embeddingModelVersion: String?
        /// Сколько суммарно говорил кластер; сумме длительностей сегментов не равен.
        public let totalMs: Int

        public init(cluster: Int, embedding: [Float]?,
                    embeddingModelVersion: String?, totalMs: Int) throws {
            self.cluster = cluster
            self.embedding = embedding
            self.embeddingModelVersion = embeddingModelVersion
            self.totalMs = totalMs
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            cluster = try box.decodeBounded(Int.self, forKey: .cluster)
            embedding = try box.decodeFiniteIfPresent([Float].self, forKey: .embedding)
            embeddingModelVersion = try box.decodeIfPresent(String.self, forKey: .embeddingModelVersion)
            totalMs = try box.decodeBounded(Int.self, forKey: .totalMs)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(cluster, forKey: .cluster)
            try box.encodeIfPresent(embedding, forKey: .embedding)
            try box.encodeIfPresent(embeddingModelVersion, forKey: .embeddingModelVersion)
            try box.encode(totalMs, forKey: .totalMs)
        }

        public func validate() throws {
            let owner = DomainOwner(contract: "C-003", type: "Transcript.Speaker")
            try owner.requireInt(cluster, "cluster")
            try owner.requireFiniteElements(embedding, "embedding")
            try owner.requireInt(totalMs, "totalMs")
            try owner.check(cluster >= 0, 9, "cluster", "cluster отрицателен")
            try validatePairing(owner)
            try owner.check(totalMs >= 0, 12, "totalMs", "totalMs отрицателен")
        }

        /// Инвариант 10: эмбеддинг и версия модели — только парой, пустого массива не бывает.
        private func validatePairing(_ owner: DomainOwner) throws {
            if embedding != nil, embeddingModelVersion == nil {
                throw owner.fail(10, "embedding", "эмбеддинг без версии модели")
            }
            if embedding == nil, embeddingModelVersion != nil {
                throw owner.fail(10, "embeddingModelVersion", "версия модели без эмбеддинга")
            }
            if let embedding, embedding.isEmpty {
                throw owner.fail(10, "embedding", "пустой массив значением не является")
            }
        }
    }
}

extension Transcript.Word {
    enum CodingKeys: String, CodingKey {
        case startMs, endMs, text, confidence, original
    }
}

extension Transcript.Segment {
    enum CodingKeys: String, CodingKey {
        case startMs, endMs, channel, speakerCluster, text, textOriginal
        case textConfidence, words
    }
}

extension Transcript.Speaker {
    enum CodingKeys: String, CodingKey {
        case cluster, embedding, embeddingModelVersion, totalMs
    }
}
