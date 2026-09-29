//  MEE-505 критерий 9: `InMemoryTranscriptRepository` держит C-010 v28 инвариант 38
//  (IR-153, MEE-490) — `transcript(id:)` возвращает `speakers` так, как их сохранил
//  `save`: те же пункты 2–4 и 8, что `StorageTests/TranscriptRepositorySpeakersTests`
//  проверяет на GRDB. Этот файл исполняется и на Linux, где `storage` не собирается.
//
//  Фикстура Z3а «системный канал без диаризации» (MEE-486/MEE-501) к моменту этой работы
//  в `main` не слита — пункт 8 проверяется на эквивалентной собственной.

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryTranscriptSpeakersTests: XCTestCase {

    private let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId

    /// Пункт 2: порядок `[3, 0]`, `Float` побитово (`-0.0`, `1e-38`).
    func test_mee505_2_speakersRoundTripKeepsOrderAndFloatBits() async throws {
        let original = try transcript(
            segments: [segment(0, 500, cluster: 0), segment(500, 1_300, cluster: 3)],
            speakers: [
                Transcript.Speaker(cluster: 3, embedding: [0.1, -0.0, 1e-38, 0.5],
                                   embeddingModelVersion: "wespeaker-1", totalMs: 12_345),
                Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 800)
            ]
        )
        let read = try await roundTrip(original)
        XCTAssertEqual(read.speakers, original.speakers)
        XCTAssertEqual(read.speakers.map(\.cluster), [3, 0])
        XCTAssertEqual(try XCTUnwrap(read.speakers[0].embedding).map(\.bitPattern),
                       try XCTUnwrap(original.speakers[0].embedding).map(\.bitPattern))
    }

    /// Пункт 3: пустой `speakers` остаётся пустым.
    func test_mee505_3_emptySpeakersRoundTrip() async throws {
        let original = try transcript(segments: [segment(0, 1_000, cluster: nil, channel: .mic)], speakers: [])
        let read = try await roundTrip(original)
        XCTAssertEqual(read.speakers, [])
    }

    /// Пункт 4: `Speaker` без сегментов своего кластера не теряется.
    func test_mee505_4_speakerWithoutSegmentsSurvives() async throws {
        let original = try transcript(
            segments: [segment(0, 1_000, cluster: 1)],
            speakers: [
                Transcript.Speaker(cluster: 1, embedding: nil, embeddingModelVersion: nil, totalMs: 1_000),
                Transcript.Speaker(cluster: 7, embedding: [0.25], embeddingModelVersion: "wespeaker-1", totalMs: 0)
            ]
        )
        let read = try await roundTrip(original)
        XCTAssertEqual(read.speakers, original.speakers)
    }

    /// Пункт 8: системный канал без диаризации — кластер 0, `Speaker(0, nil, nil, S)`.
    func test_mee505_8_systemChannelWithoutDiarizationRoundTrips() async throws {
        let original = try transcript(
            segments: [
                segment(0, 1_000, cluster: nil, channel: .mic),
                segment(1_000, 2_500, cluster: 0),
                segment(3_000, 4_000, cluster: 0)
            ],
            speakers: [Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 2_500)]
        )
        let read = try await roundTrip(original)
        XCTAssertEqual(read, original)
    }

    /// Правки сегментов `speakers` не меняют (инвариант 38, последняя фраза о методах `update*`).
    func test_mee505_segmentUpdatesKeepSpeakers() async throws {
        let original = try transcript(
            segments: [segment(0, 1_000, cluster: 0)],
            speakers: [Transcript.Speaker(cluster: 0, embedding: [0.5], embeddingModelVersion: "w", totalMs: 9)]
        )
        let repository = InMemoryTranscriptRepository()
        let header = try await repository.save(original)
        let rows = try await repository.segments(transcriptId: header.id)
        try await repository.updateAttribution([
            SegmentAttributionUpdate(segmentId: rows[0].id, personId: nil, speakerConfidence: 0.5,
                                     attributionSource: .voiceProfile)
        ])
        try await repository.updateSegmentText(segmentId: rows[0].id, text: "правка", isUserEdited: true)
        try await repository.markSegmentsUserEdited(segmentIds: [rows[0].id])
        let read = try await repository.transcript(id: header.id)
        XCTAssertEqual(read?.speakers, original.speakers)
    }

    // MARK: - Оснастка

    private func roundTrip(_ original: Transcript) async throws -> Transcript {
        let repository = InMemoryTranscriptRepository()
        let header = try await repository.save(original)
        let read = try await repository.transcript(id: header.id)
        return try XCTUnwrap(read)
    }

    private func transcript(segments: [Transcript.Segment], speakers: [Transcript.Speaker]) throws -> Transcript {
        try Transcript(
            recordingId: recordingId, language: "ru", engine: "engine", modelVersion: "1.0",
            createdAt: Date(timeIntervalSince1970: 1_789_122_912), segments: segments, speakers: speakers
        )
    }

    private func segment(
        _ startMs: Int, _ endMs: Int, cluster: Int?, channel: RecordingManifest.Channel = .system
    ) throws -> Transcript.Segment {
        try Transcript.Segment(
            startMs: startMs, endMs: endMs, channel: channel, speakerCluster: cluster,
            text: "текст", textOriginal: nil, textConfidence: nil, words: []
        )
    }
}
