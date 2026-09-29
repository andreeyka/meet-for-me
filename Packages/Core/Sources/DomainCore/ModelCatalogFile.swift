//  ModelCatalogFile, ModelManifestFile — форматы `catalog.json` и `.manifest.json`
//  (C-014 v6 §2, §2.1, §2.2; MEE-442). Плюс рукописный `init(from:)` у трёх типов §1/§3,
//  несущих целые и вещественные поля: без него §2.2 не выполняется.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Почему здесь, а не в `ModelManager`: C-014 §0 — формат файла проекта объявляется рядом
//  с `DomainJSON`, которым он читается (тот же довод, что у `RecordingManifest`/`Transcript`).
//
//  Порядок разбора (§2.2, инв. 15): `schemaVersion` читается ПЕРВЫМ действием; при
//  расхождении бросается `ModelCatalogError.manifestInvalid(message:)` с обоими числами и
//  ни одно другое поле не декодируется. Отсутствующий ключ `schemaVersion` — обычная
//  `DecodingError.keyNotFound`; её в `manifestInvalid` превращает граница читателя
//  (`refreshCatalog`, состояние модели), §2.2: «наружу `DecodingError` не выходит».
//
//  Целые поля — через `decodeBounded` (§2.2, инв. 28): `{"minRAMGB": 8.0}` читается как `8`,
//  `8.5` — битый JSON. Синтезированный `Decodable` у `ModelFile`/`ModelDescriptor`/
//  `DiarizationParameters` читал целые через `decode(Int64.self, forKey:)` — поведение
//  разборщика на литерале `8.0`/`2.36978176e8` не описано и расходится между Darwin и
//  swift-corelibs (C-001 §0.4). Запись остаётся синтезированной: ключи те же, `nil` опускается.

import Foundation

// MARK: - §2.1. Корень catalog.json

/// Корень `catalog.json` (C-014 §2.1). Читается и пишется только через `DomainJSON`.
public struct ModelCatalogFile: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let models: [ModelDescriptor]
    public let profiles: [TranscriptionProfile]

    public init(schemaVersion: Int, generatedAt: Date, models: [ModelDescriptor], profiles: [TranscriptionProfile]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.models = models
        self.profiles = profiles
    }

    /// Читает `schemaVersion` ПЕРВЫМ действием и бросает `ModelCatalogError.manifestInvalid`,
    /// если он не равен `supportedSchemaVersion`. Остальные поля при отказе не декодируются.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeBounded(Int.self, forKey: .schemaVersion)
        try Self.checkSchemaVersion(version, supported: Self.supportedSchemaVersion, file: "catalog.json")
        schemaVersion = version
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        models = try container.decode([ModelDescriptor].self, forKey: .models)
        profiles = try container.decode([TranscriptionProfile].self, forKey: .profiles)
    }

    static func checkSchemaVersion(_ version: Int, supported: Int, file: String) throws {
        guard version == supported else {
            throw ModelCatalogError.manifestInvalid(
                message: "\(file): schemaVersion \(version), поддерживается \(supported)")
        }
    }
}

// MARK: - §2.1. Корень .manifest.json

/// Корень служебного файла `.manifest.json` рядом с моделью (C-014 §2.1).
public struct ModelManifestFile: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let descriptor: ModelDescriptor

    public init(schemaVersion: Int, descriptor: ModelDescriptor) {
        self.schemaVersion = schemaVersion
        self.descriptor = descriptor
    }

    /// Тот же порядок разбора, что у `ModelCatalogFile`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeBounded(Int.self, forKey: .schemaVersion)
        try ModelCatalogFile.checkSchemaVersion(
            version, supported: Self.supportedSchemaVersion, file: ".manifest.json")
        schemaVersion = version
        descriptor = try container.decode(ModelDescriptor.self, forKey: .descriptor)
    }
}

// MARK: - §1, §3. Целые и вещественные поля — по правилу §2.2

private enum ModelFileKey: String, CodingKey {
    case name, url, sha256, sizeBytes
}

extension ModelFile {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ModelFileKey.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            url: try container.decode(URL.self, forKey: .url),
            sha256: try container.decode(String.self, forKey: .sha256),
            sizeBytes: try container.decodeBounded(Int64.self, forKey: .sizeBytes))
    }
}

private enum ModelDescriptorKey: String, CodingKey {
    case id, version, role, engine, runtime, displayName, description, sizeBytes
    case languages, files, quantization, minChip, minRAMGB, recommendedFor
}

extension ModelDescriptor {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ModelDescriptorKey.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            version: try container.decode(String.self, forKey: .version),
            role: try container.decode(ModelRole.self, forKey: .role),
            engine: try container.decode(String.self, forKey: .engine),
            runtime: try container.decode(ModelRuntime.self, forKey: .runtime),
            displayName: try container.decode(String.self, forKey: .displayName),
            description: try container.decode(String.self, forKey: .description),
            sizeBytes: try container.decodeBounded(Int64.self, forKey: .sizeBytes),
            languages: try container.decode([String].self, forKey: .languages),
            files: try container.decode([ModelFile].self, forKey: .files),
            quantization: try container.decodeIfPresent(String.self, forKey: .quantization),
            minChip: try container.decode(MinChip.self, forKey: .minChip),
            minRAMGB: try container.decodeBounded(Int.self, forKey: .minRAMGB),
            recommendedFor: try container.decode([String].self, forKey: .recommendedFor))
    }
}

private enum DiarizationParametersKey: String, CodingKey {
    case expectedSpeakers, clusteringThreshold, minSegmentMs
}

extension DiarizationParameters {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiarizationParametersKey.self)
        self.init(
            expectedSpeakers: try container.decodeBoundedIfPresent(Int.self, forKey: .expectedSpeakers),
            clusteringThreshold: try container.decodeFinite(Double.self, forKey: .clusteringThreshold),
            minSegmentMs: try container.decodeBounded(Int.self, forKey: .minSegmentMs))
    }
}
