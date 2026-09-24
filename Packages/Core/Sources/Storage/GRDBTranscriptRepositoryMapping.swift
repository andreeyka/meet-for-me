//  GRDBTranscriptRepository — половина «чтение»: сборка `Transcript`/`SegmentRow`
//  из строк. Разведена по объёму (`type_body_length`) — не по смыслу.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище

import Foundation
import GRDB
import DomainCore

extension GRDBTranscriptRepository {

    func transcript(id: UUID) async throws -> Transcript? {
        let idText = id.uuidString
        return try await withDatabase(id: idText) { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM transcripts WHERE id = ?", arguments: [idText])
            else { return nil }
            guard let recordingId = UUID(uuidString: row["recording_id"] as String) else {
                throw StorageError.dataCorrupted(
                    entity: StorageEntity.transcript, id: idText, message: "recording_id не разбирается в UUID"
                )
            }
            let segmentRows = try Row.fetchAll(
                db, sql: "SELECT * FROM segments WHERE transcript_id = ? ORDER BY start_ms", arguments: [idText]
            )
            // Словарь «Ошибки»: entity называет ЗАПРОШЕННУЮ сущность (Transcript), а не
            // таблицу, из которой пришла плохая строка (segments) — id тоже транскрипта.
            let segments = try segmentRows.map {
                try Self.domainSegment(from: $0, entity: StorageEntity.transcript, id: idText)
            }
            do {
                return try Transcript(
                    recordingId: recordingId,
                    language: row["language"], engine: row["engine"], modelVersion: row["model_version"],
                    createdAt: EpochTime.date(fromSeconds: row["created_at"]), segments: segments,
                    speakers: Self.syntheticSpeakers(from: segments)
                )
            } catch {
                throw StorageErrorMapping.map(error, entity: StorageEntity.transcript, id: idText)
            }
        }
    }

    func segments(transcriptId: UUID) async throws -> [SegmentRow] {
        let idText = transcriptId.uuidString
        return try await withDatabase(id: idText) { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM segments WHERE transcript_id = ? ORDER BY start_ms", arguments: [idText]
            )
            return try rows.map { try Self.segmentRow(from: $0, transcriptId: transcriptId) }
        }
    }

    // MARK: - Отображение строк

    /// `entity`/`id` — сущность и идентификатор, названные словарём «Ошибки» для
    /// вызывающего метода: `transcript(id:)` передаёт `("Transcript", <id транскрипта>)`,
    /// `segments(transcriptId:)` — `("Segment", <id строки>)`. Один и тот же сбой сборки
    /// сегмента отчитывается по-разному в зависимости от того, что было запрошено.
    private static func domainSegment(from row: Row, entity: String, id: String) throws -> Transcript.Segment {
        guard let channel = RecordingManifest.Channel(rawValue: row["channel"] as String) else {
            throw StorageError.dataCorrupted(entity: entity, id: id, message: "недопустимое значение channel")
        }
        let words: [Transcript.Word] = try StorageJSON.decodeFromText(
            [Transcript.Word].self, from: row["words_json"], entity: entity, id: id
        )
        do {
            return try Transcript.Segment(
                startMs: row["start_ms"], endMs: row["end_ms"], channel: channel,
                speakerCluster: row["cluster"], text: row["text"], textOriginal: row["text_original"],
                textConfidence: row["text_confidence"], words: words
            )
        } catch {
            throw StorageErrorMapping.map(error, entity: entity, id: id)
        }
    }

    private static func segmentRow(from row: Row, transcriptId: UUID) throws -> SegmentRow {
        let id: Int64 = row["id"]
        let segment = try domainSegment(from: row, entity: StorageEntity.segment, id: String(id))
        let personIdText: String? = row["person_id"]
        var attributionSource: AttributionSource?
        if let sourceText: String = row["attribution_source"] {
            guard let source = AttributionSource(rawValue: sourceText) else {
                throw StorageError.dataCorrupted(
                    entity: StorageEntity.segment, id: String(id), message: "недопустимое значение attribution_source"
                )
            }
            attributionSource = source
        }
        // Инвариант 10, половина `speaker_confidence`: не часть домена `Transcript.Segment`
        // (это поле атрибуции, не транскрипции) — границы `0...1` некому проверить, кроме
        // самого репозитория, здесь и явно.
        let speakerConfidence: Double? = row["speaker_confidence"]
        if let speakerConfidence, !(0...1).contains(speakerConfidence) {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.segment, id: String(id),
                message: "speaker_confidence (\(speakerConfidence)) вне диапазона 0...1"
            )
        }
        return SegmentRow(
            id: id, transcriptId: transcriptId, segment: segment,
            personId: personIdText.flatMap(UUID.init(uuidString:)),
            speakerConfidence: speakerConfidence, attributionSource: attributionSource,
            isUserEdited: row["is_user_edited"]
        )
    }

    /// СТРОКА (см. шапку `GRDBTranscriptRepository.swift`): схема не хранит
    /// `Transcript.speakers` — восстанавливается по одному `Speaker` на различный
    /// непустой `cluster`, `embedding`/`embeddingModelVersion` пусты, `totalMs` —
    /// сумма длительностей его сегментов.
    private static func syntheticSpeakers(from segments: [Transcript.Segment]) -> [Transcript.Speaker] {
        var totalByCluster: [Int: Int] = [:]
        for segment in segments {
            guard let cluster = segment.speakerCluster else { continue }
            totalByCluster[cluster, default: 0] += segment.endMs - segment.startMs
        }
        return totalByCluster.keys.sorted().compactMap { cluster in
            try? Transcript.Speaker(
                cluster: cluster, embedding: nil, embeddingModelVersion: nil, totalMs: totalByCluster[cluster] ?? 0
            )
        }
    }
}
