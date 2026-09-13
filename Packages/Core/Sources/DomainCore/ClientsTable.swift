//  ClientsTable — DTO таблицы правил № 2 контракта C-009, §4 «Клиенты провайдеров: `clients.json`».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Тип живёт здесь, файл — нет: `clients.json` есть ресурс модуля `detector` (§6).
//
//  Строки таблицы — bundle id приложений, а не процессов; сравнение процесса со строкой
//  вынесено в правило §4.1 и живёт отдельной чистой функцией `bundleKeyMatches` — этот тип
//  хранит строки и ничего с ними не делает.
//
//  Чтение — `DomainJSON.decode(_:from:)` (§6); своего `JSONDecoder` модуль не заводит.

import Foundation

/// Таблица клиентов провайдеров (§4). Формат файла `clients.json`.
public struct ClientsTable: Decodable, Equatable, Sendable {

    /// Версия схемы файла, которую принимает этот код.
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    /// Bundle id приложений-браузеров.
    public let browsers: [String]
    public let clients: [Client]

    public init(schemaVersion: Int = ClientsTable.currentSchemaVersion,
                browsers: [String], clients: [Client]) {
        self.schemaVersion = schemaVersion
        self.browsers = browsers
        self.clients = clients
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, browsers, clients
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decodeBounded(Int.self, forKey: .schemaVersion)
        try RuleTableSchema.require(schemaVersion, ClientsTable.currentSchemaVersion,
                                    in: box, forKey: .schemaVersion)
        browsers = try box.decode([String].self, forKey: .browsers)
        clients = try box.decode([Client].self, forKey: .clients)
    }
}

extension ClientsTable {

    /// Запись клиента: провайдер, его нативные приложения и признак вкладки браузера.
    public struct Client: Decodable, Equatable, Sendable {

        public let provider: String
        /// Пустой список означает «нативного клиента нет».
        public let bundleIds: [String]
        public let browserFallback: Bool

        public init(provider: String, bundleIds: [String], browserFallback: Bool) {
            self.provider = provider
            self.bundleIds = bundleIds
            self.browserFallback = browserFallback
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            provider = try box.decode(String.self, forKey: .provider)
            bundleIds = try box.decode([String].self, forKey: .bundleIds)
            browserFallback = try box.decode(Bool.self, forKey: .browserFallback)
        }
    }
}

// Ключи вложенного типа — отдельным расширением, как у DTO C-002 и C-003.

extension ClientsTable.Client {
    enum CodingKeys: String, CodingKey {
        case provider, bundleIds, browserFallback
    }
}
