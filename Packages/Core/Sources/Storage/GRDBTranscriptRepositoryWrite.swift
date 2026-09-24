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

    /// C-010 v19, инвариант 32 (IR-129, MEE-388): применяет постправку словарём имён.
    /// Одна транзакция: строка с `is_user_edited = 1` не трогается молча (не отказ);
    /// `wordIndex` вне диапазона либо чужой `segmentId` — `constraintViolation`, строка
    /// не меняется целиком (валидация — до записи, не после частичной правки).
    func applyTextCorrections(segmentId: Int64, text: String, corrections: [TextCorrection]) async throws {
        do {
            try await database.dbPool.write { db in
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT text, words_json, is_user_edited FROM segments WHERE id = ?",
                    arguments: [segmentId]
                ) else {
                    throw StorageError.notFound(entity: StorageEntity.segment, id: String(segmentId))
                }
                let isUserEdited: Bool = row["is_user_edited"]
                guard !isUserEdited else { return }

                let words: [Transcript.Word] = try StorageJSON.decodeFromText(
                    [Transcript.Word].self, from: row["words_json"],
                    entity: StorageEntity.segment, id: String(segmentId)
                )
                try Self.requireApplicable(corrections, to: words, segmentId: segmentId)
                let updatedWords = try Self.applying(corrections, to: words)
                let wordsJSON = try StorageJSON.encodeToText(updatedWords)
                let oldText: String = row["text"]
                try db.execute(
                    sql: """
                    UPDATE segments
                    SET text = ?, text_original = COALESCE(text_original, ?), words_json = ?, is_user_edited = 0
                    WHERE id = ?
                    """,
                    arguments: [text, oldText, wordsJSON, segmentId]
                )
            }
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.segment, id: String(segmentId))
        }
    }

    /// Ступень до записи: чужой `segmentId` либо `wordIndex` вне диапазона — вся правка
    /// отклоняется, строка не меняется НИ В ОДНОМ поле (не только `words_json`).
    private static func requireApplicable(
        _ corrections: [TextCorrection], to words: [Transcript.Word], segmentId: Int64
    ) throws {
        for correction in corrections {
            guard correction.segmentId == segmentId else {
                throw StorageError.constraintViolation(
                    message: "correction.segmentId (\(correction.segmentId)) != segmentId (\(segmentId))"
                )
            }
            guard words.indices.contains(correction.wordIndex) else {
                throw StorageError.constraintViolation(
                    message: "wordIndex (\(correction.wordIndex)) вне диапазона words (\(words.count))"
                )
            }
        }
    }

    /// `text` пишется для КАЖДОЙ правки; `.original` — та же пара, что `text`/`text_original`
    /// у сегмента: не переписывается, если уже записан (первая правка выигрывает только для
    /// `.original`, не для `text`).
    private static func applying(
        _ corrections: [TextCorrection], to words: [Transcript.Word]
    ) throws -> [Transcript.Word] {
        var updated = words
        for correction in corrections {
            let word = updated[correction.wordIndex]
            updated[correction.wordIndex] = try Transcript.Word(
                startMs: word.startMs, endMs: word.endMs, text: correction.replacement,
                confidence: word.confidence, original: word.original ?? correction.original
            )
        }
        return updated
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
