//  Пять портов репозиториев C-010 §5, не объявленных MEE-289, и `FileLayout` §1 —
//  контракт C-010 (MEE-18) v7, «Определение», §§1 и 5 (продолжение `Repositories.swift`).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-289, прецедент формы — MEE-86; этот файл — MEE-319).
//  Реализацию портов пишет модуль `storage`; фейков этих пяти протоколов и
//  `TemporaryFileLayout` в дереве нет — они предмет своей, второй задачи (см. шапку
//  `InMemoryRepositories.swift`), а не этой.
//
//  ПОЧЕМУ ВТОРОЙ ФАЙЛ, А НЕ ПРОДОЛЖЕНИЕ `Repositories.swift`. Причина техническая, не
//  контрактная: §5 контракта — один непрерывный раздел, а один файл на весь его текст
//  (MeetingRepository, RecordingRepository, TranscriptRepository — уже в дереве —
//  плюс пять новых портов и `FileLayout`) перерос бы порог `file_length` SwiftLint
//  (по умолчанию 400 строк, `.swiftlint.yml` его не переопределяет, «Core + Mac» гоняет
//  `swiftlint --strict`, warning тут красит работу). Деление — по объёму, а не по смыслу:
//  `MeetingRepository`, `PersonRepository` и `RecordingRepository` стоят в контракте
//  друг за другом, а не в этом файле, потому что первый и третий уже были объявлены до
//  этой задачи, а второй — нет.
//
//  MEE-289 объявил в `Repositories.swift` три порта §5 из восьми (`MeetingRepository`,
//  `RecordingRepository`, `TranscriptRepository`) — тогдашний план MEE-288 §6 называл
//  предметом только их. MEE-319 дописывает здесь пять оставшихся (`PersonRepository`,
//  `SpeakerProfileRepository`, `ConnectorRepository`, `MeetingOutputRepository`,
//  `SettingsRepository`), их типы (`PersonRecord`, `NameForm`, `SpeakerProfile`,
//  `ConnectorRecord`, `MeetingOutput`) и `FileLayout` §1 — ровно то, что перечень
//  MEE-189/план MEE-311 требуют для критериев C-010 v7, и ровно то, чего не было в
//  дереве на `main@5db657e`.
//
//  ПОЛНЫЙ ПОРЯДОК §5, ЧЕРЕЗ ОБА ФАЙЛА (порядок значим: правило обхода C-001 §0.2 п. 9):
//  `FileLayout` (§1) → `MeetingStatus` → `MeetingSource` → `MeetingRecord` →
//  `PersonRecord` → `NameForm` → `RecordingStatus` → `RecordingRecord` →
//  `TranscriptHeader` → `SegmentRow` → `SegmentAttributionUpdate` → `SearchHit` →
//  `SpeakerProfile` → `ConnectorRecord` → `StorageError` → `MeetingRepository` →
//  `PersonRepository` → `RecordingRepository` → `TranscriptRepository` →
//  `SpeakerProfileRepository` → `ConnectorRepository` → `MeetingOutputRepository` →
//  `MeetingOutput` → `SettingsRepository`. Первые в списке типы, уже жившие в
//  `Repositories.swift` до этой задачи, там и остались; здесь — то, что стояло
//  бы МЕЖДУ ними по контракту, но было объявлено позже, вместе с недостающими портами.
//  Порядок полей внутри каждого типа — дословно по контракту, как и в соседнем файле.

import Foundation

// MARK: - §1. Раскладка файлов

/// Раскладка каталога поддержки приложения (C-010 §1). `root` приходит снаружи —
/// модуль не знает домашний каталог и не собирает путь синглтоном (module-map,
/// «МОДУЛЬ: domain-core»).
public struct FileLayout: Sendable, Equatable {
    public let root: URL   // ~/Library/Application Support/<bundle-id>

    public init(root: URL) {
        self.root = root
    }

    public func databaseURL() -> URL {
        root.appendingPathComponent("db.sqlite")
    }

    public func recordingsRoot() -> URL {
        root.appendingPathComponent("recordings")
    }

    public func recordingDirectory(_ directoryName: String) -> URL {
        recordingsRoot().appendingPathComponent(directoryName)
    }

    public func manifestURL(_ directoryName: String) -> URL {
        recordingDirectory(directoryName).appendingPathComponent("manifest.json")
    }

    public func transcriptURL(_ directoryName: String, index: Int) -> URL {
        recordingDirectory(directoryName).appendingPathComponent("transcript.v\(index).json")
    }

    public func modelDirectory(engine: String, modelId: String, version: String) -> URL {
        root
            .appendingPathComponent("models")
            .appendingPathComponent(engine)
            .appendingPathComponent("\(modelId)@\(version)")
    }

    public func logsDirectory() -> URL {
        root.appendingPathComponent("logs")
    }
}

// MARK: - §5. Персоны и формы имён (тянутся PersonRepository)

public struct PersonRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let emails: [String]             // нормализованные, нижний регистр
    public let isMe: Bool

    public init(id: UUID, displayName: String, emails: [String], isMe: Bool) {
        self.id = id
        self.displayName = displayName
        self.emails = emails
        self.isMe = isMe
    }
}

public struct NameForm: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case full, first, last, translit, diminutive
        case userAdded = "user_added"
    }
    public let personId: UUID
    public let form: String
    public let kind: Kind

    public init(personId: UUID, form: String, kind: Kind) {
        self.personId = personId
        self.form = form
        self.kind = kind
    }
}

// MARK: - §5. Голосовые профили и коннекторы (тянутся SpeakerProfileRepository/ConnectorRepository)

public struct SpeakerProfile: Codable, Equatable, Sendable {
    public let personId: UUID
    public let embedding: [Float]
    public let modelVersion: String
    public let sampleCount: Int
    public let updatedAt: Date

    public init(
        personId: UUID,
        embedding: [Float],
        modelVersion: String,
        sampleCount: Int,
        updatedAt: Date
    ) {
        self.personId = personId
        self.embedding = embedding
        self.modelVersion = modelVersion
        self.sampleCount = sampleCount
        self.updatedAt = updatedAt
    }
}

public struct ConnectorRecord: Codable, Equatable, Sendable {
    public let id: String
    public let type: String                 // "eventkit" | "stdio"
    public let pluginId: String?
    public let settingsJson: Data
    public let keychainNamespace: String
    public let selectedCalendarIds: [String]
    public let isEnabled: Bool
    public let lastSyncAt: Date?
    public let cursor: String?
    public let lastError: String?

    public init(
        id: String,
        type: String,
        pluginId: String?,
        settingsJson: Data,
        keychainNamespace: String,
        selectedCalendarIds: [String],
        isEnabled: Bool,
        lastSyncAt: Date?,
        cursor: String?,
        lastError: String?
    ) {
        self.id = id
        self.type = type
        self.pluginId = pluginId
        self.settingsJson = settingsJson
        self.keychainNamespace = keychainNamespace
        self.selectedCalendarIds = selectedCalendarIds
        self.isEnabled = isEnabled
        self.lastSyncAt = lastSyncAt
        self.cursor = cursor
        self.lastError = lastError
    }
}

// MARK: - §5. Порты

public protocol PersonRepository: Sendable {
    func upsert(displayName: String, emails: [String]) async throws -> UUID
    func person(id: UUID) async throws -> PersonRecord?
    func person(email: String) async throws -> PersonRecord?
    func persons(ids: [UUID]) async throws -> [PersonRecord]
    func rename(personId: UUID, displayName: String) async throws
    func setMe(personId: UUID) async throws
    func me() async throws -> PersonRecord?
    func addNameForms(_ forms: [NameForm]) async throws
    func nameForms(personIds: [UUID]) async throws -> [NameForm]
}

public protocol SpeakerProfileRepository: Sendable {
    func profile(personId: UUID, modelVersion: String) async throws -> SpeakerProfile?
    func profiles(personIds: [UUID], modelVersion: String) async throws -> [SpeakerProfile]
    func upsert(_ profile: SpeakerProfile) async throws
    func delete(personId: UUID) async throws
    func deleteAll(modelVersion: String) async throws
}

public protocol ConnectorRepository: Sendable {
    func all() async throws -> [ConnectorRecord]
    func upsert(_ record: ConnectorRecord) async throws
    func setCursor(_ cursor: String?, connectorId: String) async throws
    func setSyncOutcome(at: Date, error: String?, connectorId: String) async throws
    func delete(connectorId: String) async throws
}

public protocol MeetingOutputRepository: Sendable {
    func outputs(meetingId: UUID) async throws -> [MeetingOutput]
    func save(_ output: MeetingOutput) async throws
    func markUserEdited(outputId: UUID, contentMarkdown: String) async throws
}

public struct MeetingOutput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case summary
        case decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }
    public let id: UUID
    public let meetingId: UUID
    public let kind: Kind
    public let engine: String
    public let modelVersion: String
    public let promptVersion: String
    public let contentMarkdown: String
    public let structuredJson: Data?
    public let createdAt: Date
    public let isUserEdited: Bool

    public init(
        id: UUID,
        meetingId: UUID,
        kind: Kind,
        engine: String,
        modelVersion: String,
        promptVersion: String,
        contentMarkdown: String,
        structuredJson: Data?,
        createdAt: Date,
        isUserEdited: Bool
    ) {
        self.id = id
        self.meetingId = meetingId
        self.kind = kind
        self.engine = engine
        self.modelVersion = modelVersion
        self.promptVersion = promptVersion
        self.contentMarkdown = contentMarkdown
        self.structuredJson = structuredJson
        self.createdAt = createdAt
        self.isUserEdited = isUserEdited
    }
}

public protocol SettingsRepository: Sendable {
    func value(forKey key: String) async throws -> Data?
    func setValue(_ value: Data?, forKey key: String) async throws
}
