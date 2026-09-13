//  ProvidersTable — DTO таблицы правил № 1 контракта C-009, §3 «Разбор ссылок: `providers.json`».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Тип живёт здесь, файл — нет: `providers.json` есть ресурс модуля `detector` (§6), и кладёт
//  его та задача, которая пишет резолвер. Здесь объявлено только то, чем этот файл читают:
//  §6 требует, чтобы DTO всех трёх таблиц были объявлены в `domain-core`.
//
//  Собственного `JSONDecoder` модуль не заводит: чтение — `DomainJSON.decode(_:from:)` (§6).
//  Рукописный `init(from:)` здесь не украшение: без него `priority` читался бы сырым механизмом
//  Foundation, и `{"priority": 1e1}` не прочитался бы так же, как в остальных форматах проекта,
//  — а §6 обещает обратное прямым текстом.
//
//  Порядок полей — дословно по §3; проверки значений тип на себя не берёт: битой таблицу
//  делают правила §«Поведение», и наступают они у той стороны, которая таблицу применяет.

import Foundation

/// Таблица разбора ссылок (§3). Формат файла `providers.json`.
public struct ProvidersTable: Decodable, Equatable, Sendable {

    /// Версия схемы файла, которую принимает этот код.
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let providers: [Provider]

    public init(schemaVersion: Int = ProvidersTable.currentSchemaVersion, providers: [Provider]) {
        self.schemaVersion = schemaVersion
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, providers
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decodeBounded(Int.self, forKey: .schemaVersion)
        try RuleTableSchema.require(schemaVersion, ProvidersTable.currentSchemaVersion,
                                    in: box, forKey: .schemaVersion)
        providers = try box.decode([Provider].self, forKey: .providers)
    }
}

extension ProvidersTable {

    /// Запись провайдера: ключ, отображаемое имя, приоритет и правила разбора ссылок.
    public struct Provider: Decodable, Equatable, Sendable {

        public let provider: String
        public let displayName: String
        /// Правила проверяются по возрастанию; при равенстве — в порядке следования в файле.
        public let priority: Int
        public let urlPatterns: [URLPattern]

        public init(provider: String, displayName: String, priority: Int, urlPatterns: [URLPattern]) {
            self.provider = provider
            self.displayName = displayName
            self.priority = priority
            self.urlPatterns = urlPatterns
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            provider = try box.decode(String.self, forKey: .provider)
            displayName = try box.decode(String.self, forKey: .displayName)
            priority = try box.decodeBounded(Int.self, forKey: .priority)
            urlPatterns = try box.decode([URLPattern].self, forKey: .urlPatterns)
        }
    }

    /// Правило разбора одной ссылки (§3). `null` и отсутствующий ключ — одно значение `nil`.
    public struct URLPattern: Decodable, Equatable, Sendable {

        public let hostSuffix: String
        public let pathRegex: String
        public let meetingIdQueryKey: String?
        public let passcodeQueryKey: String?

        public init(hostSuffix: String, pathRegex: String,
                    meetingIdQueryKey: String?, passcodeQueryKey: String?) {
            self.hostSuffix = hostSuffix
            self.pathRegex = pathRegex
            self.meetingIdQueryKey = meetingIdQueryKey
            self.passcodeQueryKey = passcodeQueryKey
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            hostSuffix = try box.decode(String.self, forKey: .hostSuffix)
            pathRegex = try box.decode(String.self, forKey: .pathRegex)
            meetingIdQueryKey = try box.decodeIfPresent(String.self, forKey: .meetingIdQueryKey)
            passcodeQueryKey = try box.decodeIfPresent(String.self, forKey: .passcodeQueryKey)
        }
    }
}

// Ключи вложенных типов — отдельными расширениями, как у DTO C-002 и C-003: так ни один тип
// не оказывается вложенным глубже одного уровня.

extension ProvidersTable.Provider {
    enum CodingKeys: String, CodingKey {
        case provider, displayName, priority, urlPatterns
    }
}

extension ProvidersTable.URLPattern {
    enum CodingKeys: String, CodingKey {
        case hostSuffix, pathRegex, meetingIdQueryKey, passcodeQueryKey
    }
}
