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
//  `ModelBundle` тем же пунктом тоже назван местом `DomainCore`, но здесь не объявлен:
//  ни `missingModels`, ни что-либо из «Предмета» MEE-319 его не тянет — заводить его
//  без потребителя значило бы расширять поверхность домена сверх того, что требует эта
//  задача (П2); строка для того, кто первым свяжет `beginUse(_:)`.
//
//  СТРОКА: объём `ModelCatalogPort`. C-013 §1.1 дословно требует только один метод порта —
//  `missingModels(profileId:)`. C-014 v4 объявляет тот же порт с шестнадцатью другими
//  методами (`refreshCatalog`, `models()`, `model(id:version:)`, `state(id:version:)`,
//  `download`, `cancelDownload`, `verify`, `delete`, `diskUsage`, `beginUse`, `endUse`,
//  `profiles`, `saveProfile`, `deleteProfile`, `resolve(profileId:)`, `events()`), которых
//  «Предмет» MEE-319 не перечисляет ни один. Оба законных исхода: (а) объявить здесь
//  только `missingModels` и то, что тянет его тип возврата (`ModelDescriptor` и четыре
//  типа под ним); цена — объявление придётся расширять отдельной задачей, когда домен
//  получит работу по C-014 целиком, а до тех пор `ModelCatalogPort` в `DomainCore` не
//  покрывает всей стороны-потребителя, которую называет C-014 (`model-manager`, C-016,
//  engine-xpc). (б) перенести сюда весь порт C-014 v4 дословно, с `ModelState`,
//  `ModelBundle`, `ModelUseToken`, `TranscriptionProfile`, `ResolvedProfile`,
//  `ModelCatalogEvent` и всем, что они тянут; цена — расширение публичной поверхности
//  `domain-core` контрактом, которого «Предмет» этой задачи не называет, работой, не
//  проверенной ни одним из критериев MEE-189/К50—К58, и риском разойтись со следующим
//  изданием C-014, которое эта задача не отслеживает. Продолжаю с (а): она покрывает
//  ровно то, что требует C-013 (и, значит, «Определение» C-010/C-013, критерий готовности
//  п. 1), и не берёт на себя обязанность синхронизироваться с C-014 как отдельным
//  контрактом. Вилку называю, не закрываю: решение о переносе остального порта C-014 в
//  `DomainCore` отдельной задачей — за РП.

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

public protocol ModelCatalogPort: Sendable {
    /// C-013 §1.1, инвариант 19: пустой массив — профиль готов целиком (C-014, инвариант 10);
    /// непустой — условие не выполнено; любой брошенный отказ считается выполненным условием.
    /// Тип возврата — `[ModelDescriptor]`, C-014 v4 «Определение» §4, дословно.
    func missingModels(profileId: String) async throws -> [ModelDescriptor]
}
