//  Фикстуры C-003 — «Фейк для тестов» Transcript.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки для тестов)
//
//  Все отметки времени выровнены по целой секунде; `Date()`, `UUID()` и генераторы
//  случайных чисел здесь не вызываются.

import Foundation
import DomainCore

// swiftlint:disable force_try

/// Набор транскриптов, покрывающий шесть случаев раздела «Фейк для тестов» C-003.
public enum TranscriptFixtures {

    private static let recordingId = MeetingEventFixtures.uuid("3F2504E0-4F89-41D3-9A0C-0305E82C3301")
    private static let createdAt = Date(timeIntervalSince1970: 1_789_122_912)

    /// Встреча 1:1: сегменты на `mic` и ровно один кластер на `system`.
    public static let oneOnOne: Transcript = try! Transcript(
        recordingId: recordingId,
        language: "ru",
        engine: "gigaam-sherpa-onnx",
        modelVersion: "v3.0.1",
        createdAt: createdAt,
        segments: [
            try! Transcript.Segment(
                startMs: 1_200, endMs: 3_400, channel: .mic, speakerCluster: nil,
                text: "Привет, начнём.", textOriginal: nil, textConfidence: 0.88,
                words: [
                    try! Transcript.Word(startMs: 1_200, endMs: 1_900, text: "Привет,",
                                         confidence: 0.94, original: nil),
                    try! Transcript.Word(startMs: 1_900, endMs: 2_600, text: "начнём.",
                                         confidence: 0.88, original: nil)
                ]
            ),
            try! Transcript.Segment(
                startMs: 3_000, endMs: 6_000, channel: .system, speakerCluster: 0,
                text: "Да, я готов.", textOriginal: nil, textConfidence: 0.77,
                words: [
                    try! Transcript.Word(startMs: 3_000, endMs: 3_600, text: "Да,",
                                         confidence: 0.91, original: nil),
                    try! Transcript.Word(startMs: 3_600, endMs: 6_000, text: "я готов.",
                                         confidence: 0.77, original: nil)
                ]
            )
        ],
        speakers: [
            try! Transcript.Speaker(cluster: 0, embedding: [0.1, -0.25, 0.5],
                                    embeddingModelVersion: "emb-v1", totalMs: 3_000)
        ]
    )

    /// Три кластера с перекрытием реплик: пара сегментов разных каналов пересекается
    /// по времени — без неё инвариант 14 фикстурой не покрыт.
    public static let threeClustersOverlapping: Transcript = try! Transcript(
        recordingId: recordingId,
        language: "ru-RU",
        engine: "gigaam-sherpa-onnx",
        modelVersion: "v3.0.1",
        createdAt: createdAt,
        segments: [
            segment(0, 1_000, .mic, nil, "Начали."),
            segment(500, 2_000, .system, 0, "Первый."),
            segment(2_000, 3_000, .system, 1, "Второй."),
            segment(2_500, 4_000, .mic, nil, "Ответ."),
            segment(3_000, 4_500, .system, 2, "Третий.")
        ],
        speakers: [
            try! Transcript.Speaker(cluster: 0, embedding: [0.1, 0.2, 0.3],
                                    embeddingModelVersion: "emb-v1", totalMs: 1_500),
            try! Transcript.Speaker(cluster: 1, embedding: [0.4, 0.5, 0.6],
                                    embeddingModelVersion: "emb-v1", totalMs: 1_000),
            try! Transcript.Speaker(cluster: 2, embedding: [0.7, 0.8, 0.9],
                                    embeddingModelVersion: "emb-v1", totalMs: 1_500)
        ]
    )

    /// Транскрипт без уверенностей: `confidence == nil` и `textConfidence == nil` везде —
    /// так ведут себя облачные движки.
    public static let withoutConfidence: Transcript = try! Transcript(
        recordingId: recordingId,
        language: "en",
        engine: "fluidaudio-parakeet",
        modelVersion: "v0.9",
        createdAt: createdAt,
        segments: [
            try! Transcript.Segment(
                startMs: 0, endMs: 1_500, channel: .mic, speakerCluster: nil,
                text: "Hello there.", textOriginal: nil, textConfidence: nil,
                words: [
                    try! Transcript.Word(startMs: 0, endMs: 700, text: "Hello",
                                         confidence: nil, original: nil),
                    try! Transcript.Word(startMs: 700, endMs: 1_500, text: "there.",
                                         confidence: nil, original: nil)
                ]
            ),
            segment(1_600, 3_000, .system, 0, "Hi.")
        ],
        speakers: [
            try! Transcript.Speaker(cluster: 0, embedding: nil,
                                    embeddingModelVersion: nil, totalMs: 1_400)
        ]
    )

    /// Транскрипт с постправкой имён: `original` и `textOriginal` заполнены и отличаются
    /// от действующего текста.
    public static let withNameCorrections: Transcript = try! Transcript(
        recordingId: recordingId,
        language: "ru",
        engine: "gigaam-sherpa-onnx",
        modelVersion: "v3.0.1",
        createdAt: createdAt,
        segments: [
            try! Transcript.Segment(
                startMs: 0, endMs: 2_000, channel: .mic, speakerCluster: nil,
                text: "Привет, Андрей.", textOriginal: "Привет, андрей.", textConfidence: 0.8,
                words: [
                    try! Transcript.Word(startMs: 0, endMs: 800, text: "Привет,",
                                         confidence: 0.9, original: nil),
                    try! Transcript.Word(startMs: 800, endMs: 2_000, text: "Андрей.",
                                         confidence: 0.8, original: "андрей.")
                ]
            )
        ],
        speakers: []
    )

    /// Сегмент без пословной разбивки: `words == []` при непустом `text` и непустом
    /// `textConfidence` — затем, чтобы неприменимость инварианта 8 проверялась, а не подразумевалась.
    public static let segmentWithoutWords: Transcript = try! Transcript(
        recordingId: recordingId,
        language: "ru",
        engine: "gigaam-sherpa-onnx",
        modelVersion: "v3.0.1",
        createdAt: createdAt,
        segments: [
            try! Transcript.Segment(
                startMs: 0, endMs: 2_500, channel: .system, speakerCluster: 0,
                text: "Без пословной разбивки.", textOriginal: nil, textConfidence: 0.42,
                words: []
            )
        ],
        speakers: [
            try! Transcript.Speaker(cluster: 0, embedding: [0.2, 0.3, 0.4],
                                    embeddingModelVersion: "emb-v1", totalMs: 2_500)
        ]
    )

    /// Пустой транскрипт: тишина или музыка — валидный результат, а не ошибка.
    public static let empty: Transcript = try! Transcript(
        recordingId: recordingId,
        language: "ru",
        engine: "gigaam-sherpa-onnx",
        modelVersion: "v3.0.1",
        createdAt: createdAt,
        segments: [],
        speakers: []
    )

    /// Все фикстуры набора.
    public static let allFixtures: [Transcript] = [
        oneOnOne,
        threeClustersOverlapping,
        withoutConfidence,
        withNameCorrections,
        segmentWithoutWords,
        empty
    ]

    private static func segment(_ startMs: Int, _ endMs: Int,
                                _ channel: RecordingManifest.Channel,
                                _ cluster: Int?, _ text: String) -> Transcript.Segment {
        try! Transcript.Segment(
            startMs: startMs, endMs: endMs, channel: channel, speakerCluster: cluster,
            text: text, textOriginal: nil, textConfidence: nil, words: []
        )
    }
}

// swiftlint:enable force_try
