//  ModelCatalogManager — состояние модели по диску, занятый объём, сверка (C-014 v6 §4, §4.2, §5;
//  инв. 6, 18, 24, 25, 29, 33).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  `ModelState` нигде не хранится (инв. 24): состояние вычисляется по диску при каждом
//  вопросе. В памяти процесса живут только то, чего на диске не видно: идущая загрузка,
//  исход последней неудачной попытки, счётчик расписок и кеш сверки `sha256` (файлы модели
//  меняет только `model-manager`, поэтому кеш сбрасывается загрузкой и удалением).

import Foundation
import DomainCore

/// Модель, найденная по ключу: описание и каталог на диске, либо негодный `.manifest.json`.
enum LocatedModel {
    case model(ModelDescriptor, URL)
    case invalidManifest(ModelCatalogError, URL)
}

extension ModelCatalogManager {

    public func state(id: String, version: String) async -> ModelState {
        currentState(ModelKey(id: id, version: version))
    }

    public func diskUsage() async -> [ModelDiskUsage] {
        // Инв. 18/33: по фактическим каталогам на диске, независимо от записи в каталоге;
        // нулевых строк нет.
        ModelDisk.modelDirectories(root: layout.root).compactMap { entry in
            let bytes = ModelDisk.occupiedBytes(in: entry.directory)
            guard bytes > 0 else { return nil }
            return ModelDiskUsage(modelId: entry.key.id, version: entry.key.version, bytesOnDisk: bytes)
        }
    }

    public func verify(id: String, version: String) async throws {
        let key = ModelKey(id: id, version: version)
        guard case .model(let descriptor, let directory)? = locate(key) else {
            throw ModelCatalogError.unknownModel(id: id, version: version)
        }
        switch currentState(key) {
        case .downloaded, .loaded, .error(.checksumMismatch):
            break
        default:
            throw ModelCatalogError.notDownloaded(modelId: id, version: version)
        }
        verified[key] = nil
        let outcome = verification(key, descriptor, directory)
        publish(key, currentState(key))
        if case .failed(let error) = outcome {
            throw error
        }
    }

    // MARK: - Вычисление состояния

    func currentState(_ key: ModelKey) -> ModelState {
        if sessions[key] != nil {
            return .downloading(fraction: fraction(key))
        }
        if let failure = failures[key] {
            return .error(failure)
        }
        guard let located = locate(key) else {
            return .error(.unknownModel(id: key.id, version: key.version))
        }
        switch located {
        case .invalidManifest(let error, _):
            return .error(error)
        case .model(let descriptor, let directory):
            if useCounts[key, default: 0] > 0 {
                return .loaded
            }
            return diskState(key, descriptor, directory)
        }
    }

    /// Состояние по диску (§4, §5, инв. 25): пусто — `available`; не целиком — `paused`;
    /// целиком — сверка `sha256`: `downloaded` либо `error(checksumMismatch)`.
    private func diskState(_ key: ModelKey, _ descriptor: ModelDescriptor, _ directory: URL) -> ModelState {
        let occupied = ModelDisk.occupiedBytes(in: directory)
        guard occupied > 0 else { return .available }
        let complete = descriptor.files.allSatisfy { file in
            ModelDisk.exists(ModelDisk.fileURL(in: directory, name: file.name))
        }
        guard complete else { return .paused(bytesOnDisk: occupied) }
        switch verification(key, descriptor, directory) {
        case .passed:
            return .downloaded
        case .failed(let error):
            return .error(error)
        }
    }

    /// Занятый объём / `sizeBytes`, зажатый в `0...1` (§4.2, инв. 29).
    func fraction(_ key: ModelKey) -> Double {
        guard case .model(let descriptor, let directory)? = locate(key), descriptor.sizeBytes > 0 else {
            return 0
        }
        let occupied = ModelDisk.occupiedBytes(in: directory)
        return min(1, max(0, Double(occupied) / Double(descriptor.sizeBytes)))
    }

    /// Сверка длин и `sha256` всех файлов (§5, ручная установка). Кешируется. После успешной
    /// сверки пишется `.manifest.json`, если его ещё нет (§2.1: «после успешной проверки»).
    func verification(_ key: ModelKey, _ descriptor: ModelDescriptor, _ directory: URL) -> Verification {
        if let cached = verified[key] {
            return cached
        }
        var outcome = Verification.passed
        for file in descriptor.files {
            let url = ModelDisk.fileURL(in: directory, name: file.name)
            let actual = (try? SHA256Digest.hex(ofFileAt: url)) ?? ""
            if ModelDisk.size(of: url) != file.sizeBytes || actual != file.sha256 {
                outcome = .failed(.checksumMismatch(fileName: file.name, expected: file.sha256, actual: actual))
                break
            }
        }
        if case .passed = outcome, !ModelDisk.exists(ModelDisk.manifestURL(in: directory)) {
            try? writeManifest(descriptor, in: directory)
        }
        verified[key] = outcome
        return outcome
    }

    /// `.manifest.json` — через `DomainJSON` (инв. 28): компактно, ключи отсортированы.
    func writeManifest(_ descriptor: ModelDescriptor, in directory: URL) throws {
        let file = ModelManifestFile(schemaVersion: ModelManifestFile.supportedSchemaVersion, descriptor: descriptor)
        try DomainJSON.encode(file).write(to: ModelDisk.manifestURL(in: directory), options: .atomic)
    }

    // MARK: - Поиск модели

    /// Каталожная запись — её описание; иначе (инв. 33) описание из `.manifest.json` на диске.
    /// Для каталожной модели `.manifest.json` только подтверждает происхождение (§2.1), но
    /// файл с чужим `schemaVersion` или без него даёт модели `error(manifestInvalid)`.
    func locate(_ key: ModelKey) -> LocatedModel? {
        if let descriptor = catalogDescriptor(key) {
            let directory = directory(for: descriptor)
            if let error = manifestError(in: directory) {
                return .invalidManifest(error, directory)
            }
            return .model(descriptor, directory)
        }
        guard let entry = ModelDisk.modelDirectories(root: layout.root).first(where: { $0.key == key }) else {
            return nil
        }
        let manifestURL = ModelDisk.manifestURL(in: entry.directory)
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        do {
            let manifest = try CatalogReader.manifest(from: data)
            return .model(manifest.descriptor, entry.directory)
        } catch {
            return .invalidManifest(Self.asCatalogError(error), entry.directory)
        }
    }

    private func manifestError(in directory: URL) -> ModelCatalogError? {
        guard let data = try? Data(contentsOf: ModelDisk.manifestURL(in: directory)) else { return nil }
        do {
            _ = try CatalogReader.manifest(from: data)
            return nil
        } catch {
            return Self.asCatalogError(error)
        }
    }

    static func asCatalogError(_ error: Error) -> ModelCatalogError {
        (error as? ModelCatalogError) ?? .manifestInvalid(message: String(describing: error))
    }
}
