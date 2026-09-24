//  GRDBTranscriptRepository — половина «запись»: разведена по объёму
//  (`type_body_length`) с основным файлом и с чтением — не по смыслу.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище

import Foundation
import GRDB
import DomainCore

extension GRDBTranscriptRepository {

    /// Инвариант 12 (К16): `fileIndex` — `max(file_index) + 1` для записи, с 1.
    /// Одна транзакция на весь транскрипт вместе с сегментами и FTS (триггеры
    /// схемы синхронизируют `segments_fts` сами на каждой вставке).
    func save(_ transcript: Transcript) async throws -> TranscriptHeader {
        let id = UUID()
        let now = EpochTime.seconds(Date())
        do {
            return try await database.dbPool.write { db in
                let fileIndex = try Self.nextFileIndex(recordingId: transcript.recordingId, db: db)
                try Self.insertTranscriptRow(id: id, transcript: transcript, fileIndex: fileIndex, now: now, db: db)
                for segment in transcript.segments {
                    try Self.insertSegmentRow(transcriptId: id, segment: segment, db: db)
                }
                return TranscriptHeader(
                    id: id, recordingId: transcript.recordingId, fileIndex: fileIndex,
                    engine: transcript.engine, modelVersion: transcript.modelVersion,
                    language: transcript.language, createdAt: EpochTime.date(fromSeconds: now)
                )
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    private static func nextFileIndex(recordingId: UUID, db: Database) throws -> Int {
        let maxIndex = try Int.fetchOne(
            db, sql: "SELECT MAX(file_index) FROM transcripts WHERE recording_id = ?",
            arguments: [recordingId.uuidString]
        )
        return (maxIndex ?? 0) + 1
    }

    private static func insertTranscriptRow(
        id: UUID, transcript: Transcript, fileIndex: Int, now: Int64, db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO transcripts (id, recording_id, file_index, engine, model_version, language, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id.uuidString, transcript.recordingId.uuidString, fileIndex,
                transcript.engine, transcript.modelVersion, transcript.language, now
            ]
        )
    }

    private static func insertSegmentRow(transcriptId: UUID, segment: Transcript.Segment, db: Database) throws {
        let wordsJSON = try StorageJSON.encodeToText(segment.words)
        try db.execute(
            sql: """
            INSERT INTO segments
                (transcript_id, start_ms, end_ms, channel, cluster, text, text_original,
                 text_confidence, words_json, is_user_edited)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """,
            arguments: [
                transcriptId.uuidString, segment.startMs, segment.endMs, segment.channel.rawValue,
                segment.speakerCluster, segment.text, segment.textOriginal,
                segment.textConfidence, wordsJSON
            ]
        )
    }
}
