//  Порты репозиториев MeetingRepository/RecordingRepository/TranscriptRepository и их
//  типы — контракт C-010 (MEE-18) v7, «Определение», §5 (часть).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-289, прецедент формы — MEE-86; продолжение — MEE-319).
//  Реализацию портов пишет модуль `storage` (Packages/Core/Sources/Storage/); фейк
//  восьми репозиториев неполон — см. шапку `InMemoryRepositories.swift`.
//
//  ЭТОТ ФАЙЛ ДЕРЖИТ ТРИ ПОРТА ИЗ ВОСЬМИ — те, что объявил MEE-289 (тогдашний план
//  MEE-288 §6 называл предметом только их), — и ровно те типы, без которых их подписи
//  не компилируются. Пять остальных портов §5, их типы и `FileLayout` §1 объявлены
//  MEE-319 РЯДОМ, в `RepositoriesExtended.swift`: второй файл заведён этой же задачей,
//  а не решением о делении контракта на части — причина в его собственной шапке
//  (файл вырос за порог `file_length` SwiftLint при одном файле на весь §5).
//
//  `RecordingRepository.adHoc()` (C-010 v7, §5, инвариант 29) добавлен MEE-319: метод
//  отдаёт записи без привязки к встрече по колонке, независимо от `manifest.meetingId`
//  и от `status` (инвариант 7). Фейк, который иначе не соберётся без этого метода, —
//  предмет `InMemoryRecordingRepository.swift`.
//
//  `MeetingRepository.meeting(sourceConnectorId:externalId:)` (C-010 v10, IR-118, MEE-348,
//  инвариант 30) добавлен MEE-352: пара — первичный ключ таблицы `meeting_sources` (§1),
//  метод отдаёт запись, чья строка `meeting_sources` названа этой парой, или `nil`.
//  Не изменялся v11–v13 (см. отчёт MEE-352).
//
//  `StorageError` объявлен, хотя `async throws` в Swift тип ошибки не называет и
//  компиляции он не требует: на нём стоят инварианты 20 и 21 контракта, и фейкам MEE-290
//  бросать нечем без него.
//
//  Порядок типов и порядок полей внутри типа — дословно по §5 контракта в границах
//  ТОГО, ЧТО ЛЕЖИТ В ЭТОМ ФАЙЛЕ (порядок значим: правило обхода C-001 §0.2 п. 9).
//  Полный порядок §5 целиком, через оба файла, называет шапка `RepositoriesExtended.swift`.

import Foundation

public enum MeetingStatus: String, Codable, Sendable {
    case scheduled, armed, awaitingSignal, recording
    case stopping, processing, ready, failed, skipped
}

public struct MeetingSource: Codable, Equatable, Sendable {
    public let sourceConnectorId: String
    public let externalId: String
    public let icalUid: String?
    public let lastModified: Date
    /// IR-126 (MEE-372), C-010 v18, инвариант 31: снимок `MeetingEventPayload`, каким его
    /// в последний раз отдал коннектор для этой пары — `nil`, пока источник не написал
    /// собственный снимок (строка `meeting_sources` до миграции `v1-slice2`, либо источник,
    /// заведённый до первого синка коннектора). `= nil` в `init` — существующие вызовы
    /// этим не затронуты.
    public let payload: MeetingEventPayload?

    public init(
        sourceConnectorId: String,
        externalId: String,
        icalUid: String?,
        lastModified: Date,
        payload: MeetingEventPayload? = nil
    ) {
        self.sourceConnectorId = sourceConnectorId
        self.externalId = externalId
        self.icalUid = icalUid
        self.lastModified = lastModified
        self.payload = payload
    }
}

public struct MeetingRecord: Codable, Equatable, Sendable {
    public let event: MeetingEvent          // C-001
    public let dedupKey: DedupKey?          // C-005
    public let status: MeetingStatus
    public let sources: [MeetingSource]

    public init(
        event: MeetingEvent,
        dedupKey: DedupKey?,
        status: MeetingStatus,
        sources: [MeetingSource]
    ) {
        self.event = event
        self.dedupKey = dedupKey
        self.status = status
        self.sources = sources
    }
}

public enum RecordingStatus: String, Codable, Sendable {
    case recording, stopping, finalized, failed
}

public struct RecordingRecord: Codable, Equatable, Sendable {
    public let manifest: RecordingManifest  // C-002
    public let status: RecordingStatus

    public init(manifest: RecordingManifest, status: RecordingStatus) {
        self.manifest = manifest
        self.status = status
    }
}

public struct TranscriptHeader: Codable, Equatable, Sendable {
    public let id: UUID
    public let recordingId: UUID
    public let fileIndex: Int
    public let engine: String
    public let modelVersion: String
    public let language: String
    public let createdAt: Date

    public init(
        id: UUID,
        recordingId: UUID,
        fileIndex: Int,
        engine: String,
        modelVersion: String,
        language: String,
        createdAt: Date
    ) {
        self.id = id
        self.recordingId = recordingId
        self.fileIndex = fileIndex
        self.engine = engine
        self.modelVersion = modelVersion
        self.language = language
        self.createdAt = createdAt
    }
}

public struct SegmentRow: Codable, Equatable, Sendable {
    public let id: Int64
    public let transcriptId: UUID
    public let segment: Transcript.Segment  // C-003
    public let personId: UUID?
    public let speakerConfidence: Double?
    public let attributionSource: AttributionSource?   // C-015
    public let isUserEdited: Bool

    public init(
        id: Int64,
        transcriptId: UUID,
        segment: Transcript.Segment,
        personId: UUID?,
        speakerConfidence: Double?,
        attributionSource: AttributionSource?,
        isUserEdited: Bool
    ) {
        self.id = id
        self.transcriptId = transcriptId
        self.segment = segment
        self.personId = personId
        self.speakerConfidence = speakerConfidence
        self.attributionSource = attributionSource
        self.isUserEdited = isUserEdited
    }
}

public struct SegmentAttributionUpdate: Codable, Equatable, Sendable {
    public let segmentId: Int64
    public let personId: UUID?
    public let speakerConfidence: Double?
    public let attributionSource: AttributionSource

    public init(
        segmentId: Int64,
        personId: UUID?,
        speakerConfidence: Double?,
        attributionSource: AttributionSource
    ) {
        self.segmentId = segmentId
        self.personId = personId
        self.speakerConfidence = speakerConfidence
        self.attributionSource = attributionSource
    }
}

public struct SearchHit: Codable, Equatable, Sendable {
    public let segmentId: Int64
    public let transcriptId: UUID
    public let recordingId: UUID
    public let meetingId: UUID?
    public let startMs: Int
    public let snippet: String   // фрагмент с маркерами подсветки FTS5: «<b>…</b>»
    public let rank: Double      // меньше — релевантнее (bm25 FTS5)

    public init(
        segmentId: Int64,
        transcriptId: UUID,
        recordingId: UUID,
        meetingId: UUID?,
        startMs: Int,
        snippet: String,
        rank: Double
    ) {
        self.segmentId = segmentId
        self.transcriptId = transcriptId
        self.recordingId = recordingId
        self.meetingId = meetingId
        self.startMs = startMs
        self.snippet = snippet
        self.rank = rank
    }
}

public enum StorageError: Error, Codable, Equatable, Sendable {
    case notFound(entity: String, id: String)
    case constraintViolation(message: String)
    case migrationFailed(identifier: String, message: String)
    case fileMissing(path: String)

    /// Строки прочитаны, но не складываются в доменный тип: разбор дал `DecodingError`,
    /// либо собранное значение нарушило инвариант и дало `DomainValidationError`
    /// (C-001 §0.1). Ввод-вывод при этом не отказывал, и сущность существует.
    case dataCorrupted(entity: String, id: String, message: String)

    case io(message: String)
}

public protocol MeetingRepository: Sendable {
    func save(_ record: MeetingRecord) async throws
    func meeting(id: UUID) async throws -> MeetingRecord?
    func meeting(dedupKey: DedupKey) async throws -> MeetingRecord?

    /// C-010 v10, IR-118 (MEE-348), инвариант 30: пара — первичный ключ `meeting_sources`
    /// (§1), поэтому результат не более чем один; полный перебор `meetings` не нужен.
    func meeting(sourceConnectorId: String, externalId: String) async throws -> MeetingRecord?

    func meetings(from: Date, to: Date) async throws -> [MeetingRecord]
    func setStatus(_ status: MeetingStatus, meetingId: UUID) async throws
    func delete(meetingIds: [UUID]) async throws
}

public protocol RecordingRepository: Sendable {
    func save(_ record: RecordingRecord) async throws
    func recording(id: UUID) async throws -> RecordingRecord?
    func recordings(meetingId: UUID) async throws -> [RecordingRecord]
    func unfinalized() async throws -> [RecordingRecord]
    func adHoc() async throws -> [RecordingRecord]
    func delete(recordingId: UUID, deleteFiles: Bool) async throws
}

public protocol TranscriptRepository: Sendable {
    func save(_ transcript: Transcript) async throws -> TranscriptHeader
    func headers(recordingId: UUID) async throws -> [TranscriptHeader]
    func latest(recordingId: UUID) async throws -> TranscriptHeader?
    func transcript(id: UUID) async throws -> Transcript?
    func segments(transcriptId: UUID) async throws -> [SegmentRow]
    func updateAttribution(_ updates: [SegmentAttributionUpdate]) async throws
    func updateSegmentText(segmentId: Int64, text: String, isUserEdited: Bool) async throws
    /// C-010 v19, инвариант 32 (IR-129, MEE-388): применяет постправку словарём имён.
    func applyTextCorrections(segmentId: Int64, text: String, corrections: [TextCorrection]) async throws
    func search(query: String, limit: Int, offset: Int) async throws -> [SearchHit]
}
