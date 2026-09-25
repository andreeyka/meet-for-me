//  AttributionPort — контракт C-015 (MEE-23) v9, §2–4 «Вход и выход»/«Пороги»/«Порт»,
//  дословно. Реализацию порта пишет модуль `attribution`
//  (Packages/Core/Sources/Attribution/, MEE-399 её не заводит).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  `AttributionSource` (§1) и `TextCorrection` уже объявлены в этом модуле отдельными
//  файлами (найдены прогоном ранее, до этой задачи, для чужих подписей — `SegmentRow`/
//  `applyTextCorrections`); здесь не повторяются. `SegmentAttributionUpdate` (C-010),
//  `Transcript` (C-003), `PersonRecord`/`NameForm`/`SpeakerProfile` (C-010 §5) тоже уже
//  объявлены — типы этого файла лишь тянут их своими полями.
//
//  `SpeakerAssignment.Candidate` — вложенный тип дословно по контракту (§2): один уровень
//  вложенности, `nesting` SwiftLint (types_level: 1) его не задевает.
//
//  Порядок типов и порядок полей — дословно по §2–4.

import Foundation

public struct AttributionInput: Codable, Equatable, Sendable {
    public let transcriptId: UUID
    public let transcript: Transcript
    public let segmentIds: [Int64]
    public let meetingId: UUID?
    public let attendees: [PersonRecord]
    public let me: PersonRecord?
    public let nameForms: [NameForm]
    public let profiles: [SpeakerProfile]
    public let voiceProfilesEnabled: Bool
    public let embeddingModelVersion: String
    public let userEditedSegmentIds: [Int64]

    public init(
        transcriptId: UUID,
        transcript: Transcript,
        segmentIds: [Int64],
        meetingId: UUID?,
        attendees: [PersonRecord],
        me: PersonRecord?,
        nameForms: [NameForm],
        profiles: [SpeakerProfile],
        voiceProfilesEnabled: Bool,
        embeddingModelVersion: String,
        userEditedSegmentIds: [Int64]
    ) {
        self.transcriptId = transcriptId
        self.transcript = transcript
        self.segmentIds = segmentIds
        self.meetingId = meetingId
        self.attendees = attendees
        self.me = me
        self.nameForms = nameForms
        self.profiles = profiles
        self.voiceProfilesEnabled = voiceProfilesEnabled
        self.embeddingModelVersion = embeddingModelVersion
        self.userEditedSegmentIds = userEditedSegmentIds
    }
}

public struct SpeakerAssignment: Codable, Equatable, Sendable {
    public struct Candidate: Codable, Equatable, Sendable {
        public let personId: UUID
        public let similarity: Double

        public init(personId: UUID, similarity: Double) {
            self.personId = personId
            self.similarity = similarity
        }
    }

    public let cluster: Int
    public let personId: UUID?
    public let confidence: Double
    public let source: AttributionSource
    public let runnerUp: Candidate?

    public init(cluster: Int, personId: UUID?, confidence: Double, source: AttributionSource, runnerUp: Candidate?) {
        self.cluster = cluster
        self.personId = personId
        self.confidence = confidence
        self.source = source
        self.runnerUp = runnerUp
    }
}

public struct SpeakerProfileUpdate: Codable, Equatable, Sendable {
    public let personId: UUID
    public let embedding: [Float]
    public let modelVersion: String
    public let sampleCount: Int

    public init(personId: UUID, embedding: [Float], modelVersion: String, sampleCount: Int) {
        self.personId = personId
        self.embedding = embedding
        self.modelVersion = modelVersion
        self.sampleCount = sampleCount
    }
}

public struct AttributionResult: Codable, Equatable, Sendable {
    public let transcriptId: UUID
    public let assignments: [SpeakerAssignment]
    public let segmentUpdates: [SegmentAttributionUpdate]
    public let textCorrections: [TextCorrection]
    public let profileUpdates: [SpeakerProfileUpdate]

    public init(
        transcriptId: UUID,
        assignments: [SpeakerAssignment],
        segmentUpdates: [SegmentAttributionUpdate],
        textCorrections: [TextCorrection],
        profileUpdates: [SpeakerProfileUpdate]
    ) {
        self.transcriptId = transcriptId
        self.assignments = assignments
        self.segmentUpdates = segmentUpdates
        self.textCorrections = textCorrections
        self.profileUpdates = profileUpdates
    }
}

public struct AttributionThresholds: Codable, Equatable, Sendable {
    public let profileMatchMin: Double
    public let profileMatchMargin: Double
    public let confirmedConfidenceMin: Double
    public let textConfidenceMax: Double
    public let nameSimilarityMin: Double

    public init(
        profileMatchMin: Double,
        profileMatchMargin: Double,
        confirmedConfidenceMin: Double,
        textConfidenceMax: Double,
        nameSimilarityMin: Double
    ) {
        self.profileMatchMin = profileMatchMin
        self.profileMatchMargin = profileMatchMargin
        self.confirmedConfidenceMin = confirmedConfidenceMin
        self.textConfidenceMax = textConfidenceMax
        self.nameSimilarityMin = nameSimilarityMin
    }

    /// Значения по умолчанию Среза 1; подлежат уточнению по результатам спайка качества
    /// (R3, R4) — контракт называет их предварительными, не окончательными.
    public static let slice1Defaults = AttributionThresholds(
        profileMatchMin: 0.70,
        profileMatchMargin: 0.05,
        confirmedConfidenceMin: 0.80,
        textConfidenceMax: 0.60,
        nameSimilarityMin: 0.80
    )
}

public enum AttributionError: Error, Codable, Equatable, Sendable {
    case unknownTranscript(UUID)
    case unknownCluster(Int)
    case unknownPerson(UUID)
    case embeddingModelMismatch(expected: String, actual: String)
    case segmentIdsMismatch(expected: Int, actual: Int)
    case voiceProfilesDisabled
}

public protocol AttributionPort: Sendable {
    func attribute(_ input: AttributionInput,
                   thresholds: AttributionThresholds) async throws -> AttributionResult

    /// Пользователь назвал кластер. Возвращает изменения, которые нужно записать;
    /// обновление голосового профиля — только если `voiceProfilesEnabled == true`
    /// (иначе `profileUpdates` пуст, инвариант 10).
    func confirm(transcriptId: UUID,
                 cluster: Int,
                 personId: UUID,
                 input: AttributionInput) async throws -> AttributionResult

    /// Пользователь снял назначение с кластера, не называя никого.
    func reject(transcriptId: UUID,
                cluster: Int,
                input: AttributionInput) async throws -> AttributionResult
}
