//  InMemoryTranscriptRepository — реализация `TranscriptRepository` поверх словарей, C-010
//  §«Фейк для тестов». Имя взято у контракта.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ЧТО ДЕРЖИТСЯ ИЗ ИНВАРИАНТОВ, названо поимённо:
//    * инвариант 12 — пара (`recording_id`, `file_index`) уникальна, и `file_index` есть `N`
//      из имени `transcript.v<N>.json`: `save` выдаёт следующий свободный индекс, считая от
//      **единицы** (первый файл записи — `transcript.v1.json`);
//    * инвариант 17 — `updateAttribution` НЕ ПЕРЕЗАПИСЫВАЕТ строку с `isUserEdited == true`:
//      такие сегменты пропускаются МОЛЧА, и отказом это не является;
//    * инвариант 18 — `search` отдаёт результаты по возрастанию `rank`, а при `limit == 0`
//      пустой массив;
//    * инвариант 20 — `notFound` бросает только `updateSegmentText`, обязанный изменить
//      существующую строку; чтения отдают `nil` и пустые массивы.
//
//  ПОИСК ПОДСТРОЧНЫЙ И БЕЗ РАНЖИРОВАНИЯ — это требование контракта дословно: «он проверяет
//  вызовы потребителя, а не качество FTS5». `rank` выдаётся порядком вставки сегментов, и
//  меньшее значение стоит раньше; качеством совпадения оно не является ни в каком смысле.
//
//  ИДЕНТИФИКАТОРЫ ФЕЙКА ДЕТЕРМИНИРОВАНЫ, И ЭТО РЕШЕНИЕ. `save` обязан вернуть `TranscriptHeader`
//  с полем `id`, которого во входном `Transcript` нет. Случайный `UUID()` сделал бы ответ фейка
//  невоспроизводимым между прогонами — то есть ровно тем, чего фейк и заводится избежать.
//  Поэтому `id` строится счётчиком: `00000000-0000-0000-0000-<двенадцать цифр номера>`.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА.

import Foundation
import DomainCore

/// Метод репозитория транскриптов — адрес заданного тестом отказа.
public enum TranscriptRepositoryMethod: String, Sendable, CaseIterable {
    case save
    case headers
    case latest
    case transcriptById
    case segments
    case updateAttribution
    case updateSegmentText
    case search
}

/// Фейк репозитория транскриптов. Всё поведение задаёт тест.
public final class InMemoryTranscriptRepository: TranscriptRepository, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "TranscriptRepository"

    private let lock = NSLock()
    private let log: PortCallLog

    private var headersById: [UUID: TranscriptHeader] = [:]
    private var headerOrder: [UUID] = []
    private var transcriptsById: [UUID: Transcript] = [:]
    private var rowsByTranscript: [UUID: [SegmentRow]] = [:]
    private var failures: [TranscriptRepositoryMethod: (id: String?, error: StorageError)] = [:]
    private var nextTranscriptNumber: Int = 1
    private var nextSegmentRowId: Int64 = 1

    public init(log: PortCallLog = PortCallLog()) {
        self.log = log
    }

    /// Журнал, в который пишет этот фейк. Тот же объект, что передали в инициализатор.
    public var callLog: PortCallLog { log }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Детерминированный идентификатор

    /// `n` → `00000000-0000-0000-0000-<n, двенадцать цифр>`. Формат даёт законный `UUID`
    /// при всяком неотрицательном `n`, помещающемся в двенадцать цифр; ветвь `?? UUID()`
    /// стоит на случай выхода за этот предел и покрыта вектором собственного теста.
    public static func deterministicId(_ number: Int) -> UUID {
        let tail = String(format: "%012d", number)
        return UUID(uuidString: "00000000-0000-0000-0000-\(tail)") ?? UUID()
    }

    // MARK: - Управление из теста

    public func fail(with error: StorageError, on method: TranscriptRepositoryMethod, id: String? = nil) {
        locked { failures[method] = (id: id, error: error) }
    }

    public func clearFailure(on method: TranscriptRepositoryMethod) {
        locked { failures[method] = nil }
    }

    /// Все заголовки в порядке сохранения.
    public var storedHeaders: [TranscriptHeader] {
        locked { headerOrder.compactMap { headersById[$0] } }
    }

    /// Каскад инварианта 8: уносит транскрипты записи и их сегменты. Зовёт
    /// `InMemoryRecordingRepository`, а не тест; в журнал вызовов не пишется — это
    /// следствие чужого вызова, а не свой.
    public func cascadeDelete(recordingId: UUID) {
        locked {
            let doomed = headerOrder.filter { headersById[$0]?.recordingId == recordingId }
            for identifier in doomed {
                headersById[identifier] = nil
                transcriptsById[identifier] = nil
                rowsByTranscript[identifier] = nil
            }
            headerOrder.removeAll { doomed.contains($0) }
        }
    }

    // MARK: - Оснастка

    private func failureIfAny(_ method: TranscriptRepositoryMethod, id: String?) -> StorageError? {
        locked { () -> StorageError? in
            guard let failure = failures[method] else { return nil }
            guard let wanted = failure.id else { return failure.error }
            return wanted == id ? failure.error : nil
        }
    }

    // MARK: - TranscriptRepository

    public func save(_ transcript: Transcript) async throws -> TranscriptHeader {
        log.record(port: Self.portName, method: "save(_:)", arguments: [transcript.recordingId.uuidString])
        if let error = failureIfAny(.save, id: transcript.recordingId.uuidString) {
            throw error
        }
        return locked { () -> TranscriptHeader in
            let identifier = Self.deterministicId(nextTranscriptNumber)
            nextTranscriptNumber += 1
            let taken = headerOrder
                .compactMap { headersById[$0] }
                .filter { $0.recordingId == transcript.recordingId }
                .count
            let header = TranscriptHeader(
                id: identifier,
                recordingId: transcript.recordingId,
                fileIndex: taken + 1,
                engine: transcript.engine,
                modelVersion: transcript.modelVersion,
                language: transcript.language,
                createdAt: transcript.createdAt
            )
            headersById[identifier] = header
            headerOrder.append(identifier)
            transcriptsById[identifier] = transcript
            rowsByTranscript[identifier] = transcript.segments.map { segment in
                let row = SegmentRow(
                    id: nextSegmentRowId,
                    transcriptId: identifier,
                    segment: segment,
                    personId: nil,
                    speakerConfidence: nil,
                    attributionSource: nil,
                    isUserEdited: false
                )
                nextSegmentRowId += 1
                return row
            }
            return header
        }
    }

    public func headers(recordingId: UUID) async throws -> [TranscriptHeader] {
        log.record(port: Self.portName, method: "headers(recordingId:)", arguments: [recordingId.uuidString])
        if let error = failureIfAny(.headers, id: recordingId.uuidString) {
            throw error
        }
        return locked {
            headerOrder
                .compactMap { headersById[$0] }
                .filter { $0.recordingId == recordingId }
        }
    }

    public func latest(recordingId: UUID) async throws -> TranscriptHeader? {
        log.record(port: Self.portName, method: "latest(recordingId:)", arguments: [recordingId.uuidString])
        if let error = failureIfAny(.latest, id: recordingId.uuidString) {
            throw error
        }
        return locked {
            headerOrder
                .compactMap { headersById[$0] }
                .filter { $0.recordingId == recordingId }
                .max { $0.fileIndex < $1.fileIndex }
        }
    }

    public func transcript(id: UUID) async throws -> Transcript? {
        log.record(port: Self.portName, method: "transcript(id:)", arguments: [id.uuidString])
        if let error = failureIfAny(.transcriptById, id: id.uuidString) {
            throw error
        }
        return locked { transcriptsById[id] }
    }

    public func segments(transcriptId: UUID) async throws -> [SegmentRow] {
        log.record(port: Self.portName, method: "segments(transcriptId:)", arguments: [transcriptId.uuidString])
        if let error = failureIfAny(.segments, id: transcriptId.uuidString) {
            throw error
        }
        return locked { rowsByTranscript[transcriptId] ?? [] }
    }
}

// MARK: - Правка сегментов и поиск
//
// Вынесено в расширение того же файла намеренно: тело типа иначе перерастает предел
// `type_body_length`, а разносить реализацию одного порта по двум файлам дороже — приватные
// поля видны только внутри файла, и вынос потребовал бы поднять их до внутримодульных.

extension InMemoryTranscriptRepository {

    public func updateAttribution(_ updates: [SegmentAttributionUpdate]) async throws {
        log.record(
            port: Self.portName,
            method: "updateAttribution(_:)",
            arguments: updates.map { String($0.segmentId) }
        )
        if let error = failureIfAny(.updateAttribution, id: nil) {
            throw error
        }
        locked {
            for update in updates {
                applyAttribution(update)
            }
        }
    }

    /// Инвариант 17 дословно: строка с `isUserEdited == true` пропускается МОЛЧА.
    /// Зовётся под замком.
    private func applyAttribution(_ update: SegmentAttributionUpdate) {
        for (transcriptId, rows) in rowsByTranscript {
            guard let index = rows.firstIndex(where: { $0.id == update.segmentId }) else { continue }
            let row = rows[index]
            guard !row.isUserEdited else { return }
            rowsByTranscript[transcriptId]?[index] = SegmentRow(
                id: row.id,
                transcriptId: row.transcriptId,
                segment: row.segment,
                personId: update.personId,
                speakerConfidence: update.speakerConfidence,
                attributionSource: update.attributionSource,
                isUserEdited: row.isUserEdited
            )
            return
        }
    }

    public func updateSegmentText(segmentId: Int64, text: String, isUserEdited: Bool) async throws {
        log.record(
            port: Self.portName,
            method: "updateSegmentText(segmentId:text:isUserEdited:)",
            arguments: [String(segmentId), text, String(isUserEdited)]
        )
        if let error = failureIfAny(.updateSegmentText, id: String(segmentId)) {
            throw error
        }
        switch locked({ replaceSegmentText(segmentId, text, isUserEdited) }) {
        case .replaced:
            return
        case .notFound:
            throw StorageError.notFound(entity: "segments", id: String(segmentId))
        case .invalid(let message):
            // Инвариант 21: `DomainValidationError` наружу не выходит — она сводится
            // к `dataCorrupted`. Случай живой: замена текста на системном канале, где
            // содержательный текст требует кластера (C-003, инвариант 6).
            throw StorageError.dataCorrupted(entity: "segments", id: String(segmentId), message: message)
        }
    }

    /// Исход замены текста сегмента.
    private enum TextReplacement {
        case replaced
        case notFound
        case invalid(String)
    }

    /// Зовётся под замком.
    private func replaceSegmentText(_ segmentId: Int64, _ text: String, _ isUserEdited: Bool) -> TextReplacement {
        for (transcriptId, rows) in rowsByTranscript {
            guard let index = rows.firstIndex(where: { $0.id == segmentId }) else { continue }
            let row = rows[index]
            let segment = row.segment
            let replaced: Transcript.Segment
            do {
                replaced = try Transcript.Segment(
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    channel: segment.channel,
                    speakerCluster: segment.speakerCluster,
                    text: text,
                    textOriginal: segment.textOriginal ?? segment.text,
                    textConfidence: segment.textConfidence,
                    words: segment.words
                )
            } catch {
                return .invalid(String(describing: error))
            }
            rowsByTranscript[transcriptId]?[index] = SegmentRow(
                id: row.id,
                transcriptId: row.transcriptId,
                segment: replaced,
                personId: row.personId,
                speakerConfidence: row.speakerConfidence,
                attributionSource: row.attributionSource,
                isUserEdited: isUserEdited
            )
            return .replaced
        }
        return .notFound
    }

    public func search(query: String, limit: Int, offset: Int) async throws -> [SearchHit] {
        log.record(
            port: Self.portName,
            method: "search(query:limit:offset:)",
            arguments: [query, String(limit), String(offset)]
        )
        if let error = failureIfAny(.search, id: nil) {
            throw error
        }
        guard limit > 0 else { return [] }
        return locked { () -> [SearchHit] in
            let hits = headerOrder
                .compactMap { headersById[$0] }
                .flatMap { header in
                    (rowsByTranscript[header.id] ?? [])
                        .filter { $0.segment.text.contains(query) }
                        .map { row in Self.hit(row: row, header: header, query: query) }
                }
                .sorted { $0.rank < $1.rank }
            guard offset >= 0, offset < hits.count else { return [] }
            return Array(hits[offset...].prefix(limit))
        }
    }

    private static func hit(row: SegmentRow, header: TranscriptHeader, query: String) -> SearchHit {
        SearchHit(
            segmentId: row.id,
            transcriptId: row.transcriptId,
            recordingId: header.recordingId,
            meetingId: nil,
            startMs: row.segment.startMs,
            snippet: row.segment.text.replacingOccurrences(of: query, with: "<b>\(query)</b>"),
            rank: Double(row.id)
        )
    }
}
