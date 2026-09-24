//  ModelCatalogPort (C-013 §1.1, требование объявления — C-014 v4, MEE-22) и типы,
//  которые тянет его единственный объявленный здесь метод.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ЧАСТЬ `JobQueue.swift` — по объёму, не по смыслу: с этим блоком
//  `JobQueue.swift` (423 строки) вырос за порог `file_length` SwiftLint (400 строк,
//  `.swiftlint.yml` без переопределения). `ModelCatalogPort` — часть предмета MEE-319
//  («Предмет», п. 5), просто в своём файле.
//
//  ПРАВЛЕНО ПО ВОЗВРАТУ РП НА ПРИЁМКЕ MEE-319 (PR #55): `missingModels` был объявлен
//  с выдуманным `-> [String]`. Полную подпись даёт C-014 v4 (MEE-22), «Определение» §4
//  дословно: `func missingModels(profileId: String) async throws -> [ModelDescriptor]`.
//  `[String]` этому не эквивалентен и был ошибкой первого прохода — критерий готовности
//  п. 1 («дословно по контракту») этим не соблюдался.
//
//  `ModelDescriptor` и типы, которые он тянет (`ModelRole`, `ModelRuntime`, `ModelFile`,
//  `MinChip`), объявлены здесь же, ниже, дословно по C-014 §1. Это не выход за зону:
//  C-014 §0 сам называет для `ModelRole`/`ModelRuntime` место объявления — `DomainCore`,
//  а не `ModelManager` («их одновременно используют движок C-011, фасад UI C-016 и
//  очередь C-013, а граф пакетов запрещает этим модулям зависеть друг от друга»).
//  `ModelBundle` тем же пунктом тоже назван местом `DomainCore` — до MEE-390 здесь не был
//  объявлен: ни `missingModels`, ни что-либо из «Предмета» MEE-319 его не тянуло, а заводить
//  его без потребителя значило бы расширять поверхность домена сверх того, что требовала та
//  задача (П2). Потребитель нашёлся: C-011 v5 (движок, `TranscriptionRequest.asrModel` и
//  далее) объявляет свои типы запросов полями `ModelBundle`, и модуль `EngineKit` (MEE-390)
//  первым его связал — дословно по C-014 v4/v5 «Определение» §4 (`modelId`, `version`,
//  `role`, `runtime`, `directoryURL`), без домена валидации (§0 C-001 на эти поля C-014
//  не распространяет, тем же приёмом, что и у `ModelFile`/`ModelDescriptor` этого файла).
//
//  СТРОКА: объём `ModelCatalogPort` — вилка (а)/(б), закрыта решением РП (MEE-395, 24.09,
//  по ответу архитектора в MEE-387 21:34 UTC). C-013 §1.1 дословно требует только один
//  метод порта — `missingModels(profileId:)`; C-014 (действующая версия v6, протокол тот
//  же, что в v4) объявляет тот же порт с шестнадцатью другими методами. Выбран исход (б):
//  весь порт C-014 перенесён сюда дословно — `refreshCatalog`, `models()`,
//  `model(id:version:)`, `state(id:version:)`, `download`, `cancelDownload`, `verify`,
//  `delete`, `diskUsage`, `beginUse`, `endUse`, `profiles`, `saveProfile`, `deleteProfile`,
//  `resolve(profileId:)`, `events()`, вместе с `ModelState`, `ModelCatalogEvent`,
//  `ModelCatalogError`, `ModelDiskUsage`, `ModelUseToken`, `DiarizationParameters`,
//  `TranscriptionProfile`, `ResolvedProfile`. Новое издание и `interface-request` не
//  нужны: подпись портируется как есть, не меняется ни строкой. Нужно для К46 и К53
//  перечня MEE-370 (engine-xpc, часть 2, ещё не заведена — не в этой задаче).
//
//  `ModelCatalogFile`/`ModelManifestFile` (C-014 §2 — формат `catalog.json`/`.manifest.json`)
//  сюда НЕ входят: они читаются и пишутся только `model-manager` (реализацией каталога),
//  которую эта задача явно не заводит («Не в этой задаче: EngineXPCClient и реализация
//  каталога») — типы без потребителя здесь расширяли бы поверхность домена сверх предмета
//  задачи (П2), тем же доводом, каким раньше был отклонён `ModelBundle` до его потребителя
//  в MEE-390.

import Foundation

/// C-014 v4 (MEE-22), «Определение» §1.
public enum ModelRole: String, Codable, Sendable, CaseIterable {
    case asr
    case vad
    case diarization
    case embedding
}

public enum ModelRuntime: String, Codable, Sendable {
    case coreml
    case onnx
}

/// C-014 v4/v5 (MEE-22), «Определение» §4 — модель, готовая к использованию: каталог на
/// диске уже проверен (`beginUse`), файлов по путям внутри `directoryURL` можно доверять.
public struct ModelBundle: Codable, Equatable, Sendable {
    public let modelId: String
    public let version: String
    public let role: ModelRole
    public let runtime: ModelRuntime
    public let directoryURL: URL

    public init(modelId: String, version: String, role: ModelRole, runtime: ModelRuntime, directoryURL: URL) {
        self.modelId = modelId
        self.version = version
        self.role = role
        self.runtime = runtime
        self.directoryURL = directoryURL
    }
}

/// Контракт: «порядок объявления задаёт отношение «новее»» — `Comparable` не
/// синтезируется компилятором для `enum`, поэтому оператор ниже дописан по этому
/// правилу, а не по алфавиту или `rawValue`.
public enum MinChip: String, Codable, Sendable, Comparable {
    case m1, m2, m3, m4

    private var ordinal: Int {
        switch self {
        case .m1: return 0
        case .m2: return 1
        case .m3: return 2
        case .m4: return 3
        }
    }

    public static func < (lhs: MinChip, rhs: MinChip) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

public struct ModelFile: Codable, Equatable, Sendable {
    public let name: String       // имя файла внутри каталога модели
    public let url: URL           // https-адрес на нашем CDN
    public let sha256: String     // 64 шестнадцатеричных символа в нижнем регистре
    public let sizeBytes: Int64

    public init(name: String, url: URL, sha256: String, sizeBytes: Int64) {
        self.name = name
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

public struct ModelDescriptor: Codable, Equatable, Sendable {
    public let id: String              // "gigaam-v3-e2e-ctc-int8"
    public let version: String         // semver
    public let role: ModelRole
    public let engine: String          // "fluidaudio", "sherpaonnx", "coreml-gigaam", "whispercpp"
    public let runtime: ModelRuntime
    public let displayName: String
    public let description: String
    public let sizeBytes: Int64        // сумма sizeBytes всех files
    public let languages: [String]     // BCP-47; пустой массив — языконезависимая роль
    public let files: [ModelFile]
    public let quantization: String?   // "int8", "fp16"; nil — без квантизации
    public let minChip: MinChip
    public let minRAMGB: Int
    public let recommendedFor: [String] // "ru", "en", "mixed", "fast", "quality"

    public init(
        id: String,
        version: String,
        role: ModelRole,
        engine: String,
        runtime: ModelRuntime,
        displayName: String,
        description: String,
        sizeBytes: Int64,
        languages: [String],
        files: [ModelFile],
        quantization: String?,
        minChip: MinChip,
        minRAMGB: Int,
        recommendedFor: [String]
    ) {
        self.id = id
        self.version = version
        self.role = role
        self.engine = engine
        self.runtime = runtime
        self.displayName = displayName
        self.description = description
        self.sizeBytes = sizeBytes
        self.languages = languages
        self.files = files
        self.quantization = quantization
        self.minChip = minChip
        self.minRAMGB = minRAMGB
        self.recommendedFor = recommendedFor
    }
}

/// C-014 v6 «Определение» §3, дословно.
public struct DiarizationParameters: Codable, Equatable, Sendable {
    public let expectedSpeakers: Int?
    public let clusteringThreshold: Double   // 0...1
    public let minSegmentMs: Int

    public init(expectedSpeakers: Int?, clusteringThreshold: Double, minSegmentMs: Int) {
        self.expectedSpeakers = expectedSpeakers
        self.clusteringThreshold = clusteringThreshold
        self.minSegmentMs = minSegmentMs
    }
}

public struct TranscriptionProfile: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let language: String?          // BCP-47; nil — движок решает сам
    public let asrModelId: String
    public let vadModelId: String?
    public let diarizationModelId: String?
    public let embeddingModelId: String?
    public let diarization: DiarizationParameters
    public let isBuiltIn: Bool            // встроенный профиль нельзя удалить и нельзя изменить

    public init(
        id: String,
        displayName: String,
        language: String?,
        asrModelId: String,
        vadModelId: String?,
        diarizationModelId: String?,
        embeddingModelId: String?,
        diarization: DiarizationParameters,
        isBuiltIn: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.language = language
        self.asrModelId = asrModelId
        self.vadModelId = vadModelId
        self.diarizationModelId = diarizationModelId
        self.embeddingModelId = embeddingModelId
        self.diarization = diarization
        self.isBuiltIn = isBuiltIn
    }
}

public struct ResolvedProfile: Codable, Equatable, Sendable {
    public let profileId: String
    public let language: String?
    public let asr: ModelBundle
    public let vad: ModelBundle?
    public let diarization: ModelBundle?
    public let embedding: ModelBundle?
    public let diarizationParameters: DiarizationParameters

    public init(
        profileId: String,
        language: String?,
        asr: ModelBundle,
        vad: ModelBundle?,
        diarization: ModelBundle?,
        embedding: ModelBundle?,
        diarizationParameters: DiarizationParameters
    ) {
        self.profileId = profileId
        self.language = language
        self.asr = asr
        self.vad = vad
        self.diarization = diarization
        self.embedding = embedding
        self.diarizationParameters = diarizationParameters
    }
}

/// C-014 v6 «Определение» §4. Не `Codable` — несёт `ModelCatalogError` (тоже не `Codable`
/// требуется, но здесь ассоциированное значение делает `Equatable`/`Sendable` без `Codable`
/// синтезируемыми, а `Codable` контракт для этого типа не называет; см. «Что вне контракта»:
/// через C-016 тип уходит в UI внутри процесса, сериализация ему не нужна).
public enum ModelState: Equatable, Sendable {
    case available                        // есть в каталоге; на диске нет ни одного байта
    case downloading(fraction: Double)    // 0...1; считается от занятого объёма (§4.2)
    case paused(bytesOnDisk: Int64)       // загрузка прервана; bytesOnDisk — занятый объём (§4.2), > 0
    case downloaded                       // все файлы на диске, sha256 сверены
    case loaded                           // используется идущей задачей (§4.1)
    case error(ModelCatalogError)
}

public enum ModelCatalogEvent: Equatable, Sendable {
    case catalogRefreshed(modelCount: Int)
    case stateChanged(modelId: String, version: String, state: ModelState)
    case profilesChanged
}

public enum ModelCatalogError: Error, Codable, Equatable, Sendable {
    case manifestInvalid(message: String)
    case manifestUnreachable(message: String)
    case unknownModel(id: String, version: String)
    case unknownProfile(id: String)
    case notDownloaded(modelId: String, version: String)
    case checksumMismatch(fileName: String, expected: String, actual: String)
    case downloadFailed(message: String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case unsupportedChip(required: MinChip)
    case insufficientRAM(requiredGB: Int)
    case modelInUseByProfile(modelId: String, profileIds: [String])
    case builtInProfileImmutable(id: String)
    case cancelled
}

public struct ModelDiskUsage: Codable, Equatable, Sendable {
    public let modelId: String
    public let version: String
    public let bytesOnDisk: Int64         // занятый моделью объём (§4.2), включая .part

    public init(modelId: String, version: String, bytesOnDisk: Int64) {
        self.modelId = modelId
        self.version = version
        self.bytesOnDisk = bytesOnDisk
    }
}

/// Расписка о том, что набор моделей занят идущей работой. Выдаётся `beginUse`,
/// гасится `endUse`. Между процессами и перезапусками не живёт (инвариант 24).
public struct ModelUseToken: Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public protocol ModelCatalogPort: Sendable {
    func refreshCatalog() async throws
    func models() async -> [ModelDescriptor]
    func model(id: String, version: String) async -> ModelDescriptor?
    func state(id: String, version: String) async -> ModelState
    func download(id: String, version: String) async throws
    func cancelDownload(id: String, version: String) async
    func verify(id: String, version: String) async throws
    func delete(id: String, version: String) async throws
    func diskUsage() async -> [ModelDiskUsage]

    /// Инвариант 22: атомарна — если хотя бы один бандл не в `.downloaded` и не в `.loaded`,
    /// бросает `notDownloaded(modelId:version:)`, ни одна модель набора не помечается.
    func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken
    /// Инвариант 23: идемпотентна — повторное погашение и погашение неизвестной расписки —
    /// операция без эффекта, а не ошибка (то же правило, что у `cancel` в C-013).
    func endUse(_ token: ModelUseToken) async

    func profiles() async -> [TranscriptionProfile]
    func saveProfile(_ profile: TranscriptionProfile) async throws
    func deleteProfile(id: String) async throws
    /// Инвариант 19: `ModelBundle.directoryURL`, выданный здесь, существует на диске в
    /// момент выдачи и содержит все файлы из `ModelDescriptor.files`.
    func resolve(profileId: String) async throws -> ResolvedProfile
    /// C-013 §1.1, инвариант 19: пустой массив — профиль готов целиком (C-014, инвариант 10);
    /// непустой — условие не выполнено; любой брошенный отказ считается выполненным условием.
    /// Тип возврата — `[ModelDescriptor]`, C-014 v4 «Определение» §4, дословно.
    func missingModels(profileId: String) async throws -> [ModelDescriptor]

    func events() -> AsyncStream<ModelCatalogEvent>
}
