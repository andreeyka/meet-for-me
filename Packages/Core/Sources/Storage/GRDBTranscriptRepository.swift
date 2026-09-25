//  GRDBTranscriptRepository — реализация `TranscriptRepository`, C-010 (MEE-18) v8 §5.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  Тело разведено по объёму на три файла, не по смыслу (тот же приём, что у
//  `GRDBMeetingRepository`): здесь — протокол целиком, кроме записи (`…Write.swift`)
//  и сборки `Transcript` на чтении (`…Mapping.swift`).
//
//  СТРОКА: контракт не хранит `Transcript.speakers` (эмбеддинг, версия модели,
//  суммарная длительность) ни в одной колонке схемы §3 — только `segments.cluster`
//  на уровне отдельного сегмента. При сборке `Transcript` на чтении `speakers`
//  восстанавливается синтетически: один `Speaker` на каждый различный непустой
//  `cluster`, встреченный среди сегментов, `embedding`/`embeddingModelVersion` —
//  `nil`, `totalMs` — сумма длительностей его сегментов. Этого достаточно, чтобы
//  собственные инварианты `Transcript` (уникальность кластеров, каждый
//  `speakerCluster` сегмента ссылается на существующего `Speaker`) выполнялись
//  тождественно, но исходные `embedding`/`embeddingModelVersion`/`totalMs`,
//  если они были при записи (контракт не даёт им колонки), не переживают
//  круг «запись → чтение». Ни один критерий К1—К49/К85—К87 это не проверяет.
//  За контракт не решаю.

import Foundation
import GRDB
import DomainCore

final class GRDBTranscriptRepository: TranscriptRepository {

    let database: StorageDatabase

    init(database: StorageDatabase) {
        self.database = database
    }

    func headers(recordingId: UUID) async throws -> [TranscriptHeader] {
        try await withDatabase(id: recordingId.uuidString) { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM transcripts WHERE recording_id = ? ORDER BY created_at DESC",
                arguments: [recordingId.uuidString]
            )
            return try rows.map { try Self.header(from: $0) }
        }
    }

    func latest(recordingId: UUID) async throws -> TranscriptHeader? {
        try await withDatabase(id: recordingId.uuidString) { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM transcripts WHERE recording_id = ? ORDER BY created_at DESC LIMIT 1",
                arguments: [recordingId.uuidString]
            ) else { return nil }
            return try Self.header(from: row)
        }
    }

    /// К22, инвариант 17: автоматические источники пропускают молча строки с
    /// `is_user_edited = 1`. Исключение (C-010 v25, IR-135, MEE-421): `attributionSource
    /// == .user` записывается всегда, независимо от `is_user_edited` — решение человека
    /// по кластеру не должно отклоняться собственной же пометкой правки. `is_user_edited`
    /// эта запись не трогает — он остаётся тем, чем был (обычно 1, выставлен заранее
    /// `markSegmentsUserEdited`).
    func updateAttribution(_ updates: [SegmentAttributionUpdate]) async throws {
        do {
            try await database.dbPool.write { db in
                for update in updates {
                    let sql = update.attributionSource == .user
                        ? """
                          UPDATE segments SET person_id = ?, speaker_confidence = ?, attribution_source = ?
                          WHERE id = ?
                          """
                        : """
                          UPDATE segments SET person_id = ?, speaker_confidence = ?, attribution_source = ?
                          WHERE id = ? AND is_user_edited = 0
                          """
                    try db.execute(
                        sql: sql,
                        arguments: [
                            update.personId?.uuidString, update.speakerConfidence,
                            update.attributionSource.rawValue, update.segmentId
                        ]
                    )
                }
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    func updateSegmentText(segmentId: Int64, text: String, isUserEdited: Bool) async throws {
        do {
            let changed = try await database.dbPool.write { db -> Int in
                try db.execute(
                    sql: "UPDATE segments SET text = ?, is_user_edited = ? WHERE id = ?",
                    arguments: [text, isUserEdited, segmentId]
                )
                return db.changesCount
            }
            guard changed > 0 else {
                throw StorageError.notFound(entity: StorageEntity.segment, id: String(segmentId))
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    /// C-010 v25, инвариант 34 (IR-135, MEE-421): ставит только `is_user_edited = 1` —
    /// `text`/`text_original`/`words_json`/атрибуцию не трогает. Пустой список — ничего не
    /// делает без обращения к базе. Повтор id в списке безвреден: `UPDATE ... WHERE id = ?`
    /// идемпотентен сам по себе, `Set` лишь исключает лишний проход. Чужой id —
    /// `constraintViolation`, не `notFound`: контракт называет именно этот случай дословно.
    /// Транзакция одна на весь список — брошенная ошибка откатывает уже применённые правки.
    func markSegmentsUserEdited(segmentIds: [Int64]) async throws {
        guard !segmentIds.isEmpty else { return }
        do {
            try await database.dbPool.write { db in
                for segmentId in Set(segmentIds) {
                    try db.execute(
                        sql: "UPDATE segments SET is_user_edited = 1 WHERE id = ?", arguments: [segmentId]
                    )
                    guard db.changesCount > 0 else {
                        throw StorageError.constraintViolation(
                            message: "markSegmentsUserEdited: сегмент \(segmentId) не найден"
                        )
                    }
                }
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    /// К23, инвариант 18: `rank` неубывает (bm25 — меньше значит релевантнее);
    /// `limit = 0` даёт пустой массив средствами самого SQL (`LIMIT 0`), не веткой кода.
    func search(query: String, limit: Int, offset: Int) async throws -> [SearchHit] {
        try await withDatabase(id: "?") { db in
            let rows = try Row.fetchAll(db, sql: Self.searchSQL, arguments: [query, limit, offset])
            return try rows.map { try Self.searchHit(from: $0) }
        }
    }

    // MARK: - Оснастка, общая для файлов расширений

    func withDatabase<T>(id: String, _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await database.dbPool.read(body)
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.transcript, id: id)
        }
    }

    private static let searchSQL = """
        SELECT s.id AS segment_id, s.transcript_id, t.recording_id, r.meeting_id, s.start_ms,
               snippet(segments_fts, 0, '<b>', '</b>', '…', 10) AS snippet,
               bm25(segments_fts) AS rank
        FROM segments_fts
        JOIN segments s ON s.id = segments_fts.rowid
        JOIN transcripts t ON t.id = s.transcript_id
        JOIN recordings r ON r.id = t.recording_id
        WHERE segments_fts MATCH ?
        ORDER BY rank
        LIMIT ? OFFSET ?
        """

    private static func header(from row: Row) throws -> TranscriptHeader {
        let idText: String = row["id"]
        guard let id = UUID(uuidString: idText),
              let recordingId = UUID(uuidString: row["recording_id"] as String) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.transcript, id: idText, message: "id/recording_id не разбираются в UUID"
            )
        }
        return TranscriptHeader(
            id: id, recordingId: recordingId, fileIndex: row["file_index"], engine: row["engine"],
            modelVersion: row["model_version"], language: row["language"],
            createdAt: EpochTime.date(fromSeconds: row["created_at"])
        )
    }

    private static func searchHit(from row: Row) throws -> SearchHit {
        let transcriptIdText: String = row["transcript_id"]
        guard let transcriptId = UUID(uuidString: transcriptIdText),
              let recordingId = UUID(uuidString: row["recording_id"] as String) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.transcript, id: transcriptIdText, message: "id не разбирается в UUID"
            )
        }
        let meetingIdText: String? = row["meeting_id"]
        return SearchHit(
            segmentId: row["segment_id"], transcriptId: transcriptId, recordingId: recordingId,
            meetingId: meetingIdText.flatMap(UUID.init(uuidString:)), startMs: row["start_ms"],
            snippet: row["snippet"], rank: row["rank"]
        )
    }
}
