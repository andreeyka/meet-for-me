//  Фикстуры C-015 (MEE-23) §«Фейк для тестов» — шесть именованных входов `AttributionInput`
//  для тестов самого модуля `attribution` (MEE-399, шаги 1–2 плана MEE-396).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки для тестов)
//
//  Все отметки времени выровнены по целой секунде; `Date()`, `UUID()` и генераторы
//  случайных чисел здесь не вызываются — тот же приём, что у `TranscriptFixtures`.

import Foundation
import DomainCore

// swiftlint:disable force_try

/// Шесть входов раздела «Фейк для тестов» C-015, по одному на абзац дословно.
public enum AttributionFixtures {

    private static let createdAt = Date(timeIntervalSince1970: 1_789_122_912)

    private static let me = PersonRecord(
        id: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000A0"),
        displayName: "Я", emails: [], isMe: true
    )

    /// Встреча 1:1 без профилей — проверяет правило 3 («встреча один на один»):
    /// `attendees` — ровно двое, один `me`, системный кластер в транскрипте один.
    public static let oneOnOneWithoutProfiles: AttributionInput = {
        let otherPerson = PersonRecord(
            id: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000A1"),
            displayName: "Второй участник", emails: [], isMe: false
        )
        return AttributionInput(
            transcriptId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000B1"),
            transcript: TranscriptFixtures.oneOnOne,
            segmentIds: [1, 2],
            meetingId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000C1"),
            attendees: [me, otherPerson],
            me: me,
            nameForms: [],
            profiles: [],
            voiceProfilesEnabled: true,
            embeddingModelVersion: "emb-v1",
            userEditedSegmentIds: []
        )
    }()

    /// Встреча с тремя участниками и профилями, где лучший и второй кандидаты отличаются
    /// меньше, чем `AttributionThresholds.profileMatchMargin` (0.05 по умолчанию) —
    /// проверяет отказ от назначения правилом 2: кластер `[1, 0]` косинусно ближе всего к
    /// профилю A (`[1, 0]`, сходство 1.0) и почти так же близок к профилю B
    /// (`[0.97, 0.2431]`, сходство 0.97) — разрыв 0.03 меньше порога.
    public static let threeParticipantsAmbiguousProfileMatch: AttributionInput = {
        let personA = MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000A2")
        let personB = MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000A3")
        let personC = MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000A4")
        let attendees = [
            me,
            PersonRecord(id: personA, displayName: "Участник A", emails: [], isMe: false),
            PersonRecord(id: personB, displayName: "Участник B", emails: [], isMe: false),
            PersonRecord(id: personC, displayName: "Участник C", emails: [], isMe: false)
        ]
        let profiles = [
            SpeakerProfile(
                personId: personA, embedding: [1.0, 0.0], modelVersion: "emb-v1",
                sampleCount: 5, updatedAt: createdAt
            ),
            SpeakerProfile(
                personId: personB, embedding: [0.97, 0.2431], modelVersion: "emb-v1",
                sampleCount: 5, updatedAt: createdAt
            ),
            SpeakerProfile(
                personId: personC, embedding: [0.0, 1.0], modelVersion: "emb-v1",
                sampleCount: 5, updatedAt: createdAt
            )
        ]
        let transcript = try! Transcript(
            recordingId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000D2"),
            language: "ru", engine: "gigaam-sherpa-onnx", modelVersion: "v3.0.1", createdAt: createdAt,
            segments: [
                try! Transcript.Segment(
                    startMs: 0, endMs: 2_000, channel: .system, speakerCluster: 0,
                    text: "Добрый день, коллеги.", textOriginal: nil, textConfidence: 0.9, words: []
                )
            ],
            speakers: [
                try! Transcript.Speaker(
                    cluster: 0, embedding: [1.0, 0.0], embeddingModelVersion: "emb-v1", totalMs: 2_000
                )
            ]
        )
        return AttributionInput(
            transcriptId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000B2"),
            transcript: transcript,
            segmentIds: [1],
            meetingId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000C2"),
            attendees: attendees,
            me: me,
            nameForms: [],
            profiles: profiles,
            voiceProfilesEnabled: true,
            embeddingModelVersion: "emb-v1",
            userEditedSegmentIds: []
        )
    }()

    /// Транскрипт без эмбеддингов (`embedding == nil` у всех спикеров) — правило 2 сравнить
    /// нечего, кластер уходит по правилу 3 или остаётся неопознанным (правило 4).
    public static let noEmbeddings: AttributionInput = AttributionInput(
        transcriptId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000B3"),
        transcript: TranscriptFixtures.withoutConfidence,
        segmentIds: [1, 2],
        meetingId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000C3"),
        attendees: [me],
        me: me,
        nameForms: [],
        profiles: [],
        voiceProfilesEnabled: true,
        embeddingModelVersion: "emb-v1",
        userEditedSegmentIds: []
    )

    /// Сегмент с неуверенным словом (уверенность ниже `textConfidenceMax`, 0.60 по
    /// умолчанию), близким к имени участника из `nameForms` — проверяет постправку (§6.3
    /// шаг 8, правило постправки имён).
    public static let uncertainWordNearParticipantName: AttributionInput = {
        let ivan = MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000A5")
        let attendees = [me, PersonRecord(id: ivan, displayName: "Иван", emails: [], isMe: false)]
        let transcript = try! Transcript(
            recordingId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000D4"),
            language: "ru", engine: "gigaam-sherpa-onnx", modelVersion: "v3.0.1", createdAt: createdAt,
            segments: [
                try! Transcript.Segment(
                    startMs: 0, endMs: 2_000, channel: .system, speakerCluster: 0,
                    text: "Спасибо, Ивам.", textOriginal: nil, textConfidence: 0.35,
                    words: [
                        try! Transcript.Word(startMs: 0, endMs: 900, text: "Спасибо,", confidence: 0.9, original: nil),
                        try! Transcript.Word(startMs: 900, endMs: 2_000, text: "Ивам.", confidence: 0.35, original: nil)
                    ]
                )
            ],
            speakers: [
                try! Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 2_000)
            ]
        )
        return AttributionInput(
            transcriptId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000B4"),
            transcript: transcript,
            segmentIds: [1],
            meetingId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000C4"),
            attendees: attendees,
            me: me,
            nameForms: [NameForm(personId: ivan, form: "Иван", kind: .full)],
            profiles: [],
            voiceProfilesEnabled: true,
            embeddingModelVersion: "emb-v1",
            userEditedSegmentIds: []
        )
    }()

    /// Сегмент, уже помеченный `is_user_edited`, чей идентификатор стоит в
    /// `userEditedSegmentIds` этого же входа — проверяет инвариант 8 и часть (в)
    /// инварианта 21. До появления `userEditedSegmentIds` (v4) эта фикстура была
    /// невыполнима: пометка живёт в строке базы, а вход строит только значения.
    public static let segmentAlreadyUserEdited: AttributionInput = {
        let transcript = try! Transcript(
            recordingId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000D5"),
            language: "ru", engine: "gigaam-sherpa-onnx", modelVersion: "v3.0.1", createdAt: createdAt,
            segments: [
                try! Transcript.Segment(
                    startMs: 0, endMs: 1_500, channel: .system, speakerCluster: 0,
                    text: "Правка человека, автоматика не трогает.", textOriginal: nil,
                    textConfidence: 0.3, words: []
                )
            ],
            speakers: [
                try! Transcript.Speaker(
                    cluster: 0, embedding: [0.2, 0.4], embeddingModelVersion: "emb-v1", totalMs: 1_500
                )
            ]
        )
        return AttributionInput(
            transcriptId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000B5"),
            transcript: transcript,
            segmentIds: [1],
            meetingId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000C5"),
            attendees: [me],
            me: me,
            nameForms: [],
            profiles: [],
            voiceProfilesEnabled: true,
            embeddingModelVersion: "emb-v1",
            userEditedSegmentIds: [1]
        )
    }()

    /// Встреча с системными сегментами, один из которых состоит из одних пробелов и
    /// пришёл с `speakerCluster == nil` — проверяет инвариант 22 вместе с его границей:
    /// C-003 §Segment допускает `speakerCluster == nil` на `.system` ровно тогда, когда
    /// текст после `trimmingCharacters` пуст (инвариант 6 C-003).
    public static let whitespaceOnlySystemSegmentNoCluster: AttributionInput = {
        let transcript = try! Transcript(
            recordingId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000D6"),
            language: "ru", engine: "gigaam-sherpa-onnx", modelVersion: "v3.0.1", createdAt: createdAt,
            segments: [
                try! Transcript.Segment(
                    startMs: 0, endMs: 1_000, channel: .system, speakerCluster: nil,
                    text: "   ", textOriginal: nil, textConfidence: nil, words: []
                ),
                try! Transcript.Segment(
                    startMs: 1_000, endMs: 3_000, channel: .system, speakerCluster: 0,
                    text: "Теперь по делу.", textOriginal: nil, textConfidence: 0.85, words: []
                )
            ],
            speakers: [
                try! Transcript.Speaker(
                    cluster: 0, embedding: [0.5, 0.5], embeddingModelVersion: "emb-v1", totalMs: 2_000
                )
            ]
        )
        return AttributionInput(
            transcriptId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000B6"),
            transcript: transcript,
            segmentIds: [1, 2],
            meetingId: MeetingEventFixtures.uuid("00000000-0000-0000-0000-0000000000C6"),
            attendees: [me],
            me: me,
            nameForms: [],
            profiles: [],
            voiceProfilesEnabled: true,
            embeddingModelVersion: "emb-v1",
            userEditedSegmentIds: []
        )
    }()

    /// Все шесть входов набора.
    public static let allFixtures: [AttributionInput] = [
        oneOnOneWithoutProfiles,
        threeParticipantsAmbiguousProfileMatch,
        noEmbeddings,
        uncertainWordNearParticipantName,
        segmentAlreadyUserEdited,
        whitespaceOnlySystemSegmentNoCluster
    ]
}

// swiftlint:enable force_try
