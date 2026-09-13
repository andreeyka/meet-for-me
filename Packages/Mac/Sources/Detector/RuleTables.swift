//  RuleTables — правила двух таблиц `detector`, построенные из байтов один раз.
//
//  C-009 §3, §4, §4.1, §6, §«Поведение»; инварианты 1, 7, 8, 9, 22.
//
//  Построение из байтов — чистая функция `build(providers:clients:)` (шов Ш2 (ii)): чтение
//  идёт через `DomainJSON.decode(_:from:)` в DTO, объявленные в `domain-core`, а дальше правило
//  либо строится целиком, либо не строится вовсе. Битая таблица — ошибка, а не пропуск правила,
//  не пустая таблица и не откат к другой копии.
//
//  Однократность (инвариант 22) держит `static let shipped`: ресурс читается при первом
//  обращении и больше никогда за жизнь процесса, и второго набора правил не существует.

import DomainCore
import Foundation

/// Причина, по которой таблица правил битая сверх отказа самого разбора.
enum RuleTableError: Error, Equatable {
    /// Сборка не положила ресурс.
    case resourceMissing(String)
    /// `pathRegex` не компилируется как регулярное выражение ICU.
    case invalidPathRegex(provider: String, pattern: String)
    /// Строка `browsers` и строка `clients[].bundleIds` дают один ключ приложения (IR-049).
    case roleConflict(browser: String, client: String)
}

/// Скомпилированное правило разбора одной ссылки (§3).
struct LinkRule: @unchecked Sendable {
    let provider: String
    let hostSuffix: String
    let pathRegex: NSRegularExpression
    let hasMeetingIdGroup: Bool
    let hasPasscodeGroup: Bool
    let meetingIdQueryKey: String?
    let passcodeQueryKey: String?
}

/// Правила обеих таблиц `detector`. Значение неизменяемо.
struct RuleTables: Sendable {

    /// Правила разбора ссылок в порядке проверки: по возрастанию `priority`, при равенстве —
    /// в порядке следования в файле.
    let linkRules: [LinkRule]
    let browsers: [String]
    let clients: [ClientsTable.Client]

    /// Таблицы, поставленные сборкой модуля, прочитанные один раз за жизнь процесса.
    static let shipped = Result<RuleTables, Error> {
        try build(providers: DetectorResources.bytes(of: .providers),
                  clients: DetectorResources.bytes(of: .clients))
    }

    /// `Data` → правила. Ни ресурсов, ни файловой системы, ни времени, ни состояния системы.
    static func build(providers: Data, clients: Data) throws -> RuleTables {
        let providersTable = try DomainJSON.decode(ProvidersTable.self, from: providers)
        let clientsTable = try DomainJSON.decode(ClientsTable.self, from: clients)
        try requireNoRoleConflict(clientsTable)
        return RuleTables(linkRules: try compile(providersTable),
                          browsers: clientsTable.browsers,
                          clients: clientsTable.clients)
    }

    private static func compile(_ table: ProvidersTable) throws -> [LinkRule] {
        let ordered = table.providers.enumerated().sorted { lhs, rhs in
            (lhs.element.priority, lhs.offset) < (rhs.element.priority, rhs.offset)
        }
        return try ordered.flatMap { entry in
            try entry.element.urlPatterns.map { try compile($0, provider: entry.element.provider) }
        }
    }

    private static func compile(_ pattern: ProvidersTable.URLPattern, provider: String) throws -> LinkRule {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern.pathRegex)
        } catch {
            throw RuleTableError.invalidPathRegex(provider: provider, pattern: pattern.pathRegex)
        }
        return LinkRule(provider: provider,
                        hostSuffix: pattern.hostSuffix,
                        pathRegex: regex,
                        hasMeetingIdGroup: pattern.pathRegex.contains("(?<meetingId>"),
                        hasPasscodeGroup: pattern.pathRegex.contains("(?<passcode>"),
                        meetingIdQueryKey: pattern.meetingIdQueryKey,
                        passcodeQueryKey: pattern.passcodeQueryKey)
    }

    /// Спор ролей по IR-049 — парами строк, в обе стороны: шаг 2 §4.1, применённый к двум
    /// строкам таблицы. Сравнение — функцией `bundleKeyMatches` из `domain-core`, а не своим.
    private static func requireNoRoleConflict(_ table: ClientsTable) throws {
        for browser in table.browsers {
            for client in table.clients.flatMap(\.bundleIds)
            where bundleKeyMatches(appKey: client, entry: browser)
                || bundleKeyMatches(appKey: browser, entry: client) {
                throw RuleTableError.roleConflict(browser: browser, client: client)
            }
        }
    }
}

// MARK: - Ответы по таблице клиентов (§4, §4.1)

extension RuleTables {

    /// Инвариант 9: существует строка `browsers`, совпавшая с ключом по §4.1.
    func isBrowser(appKey: String) -> Bool {
        browsers.contains { bundleKeyMatches(appKey: appKey, entry: $0) }
    }

    /// Провайдер нативного клиента по ключу приложения; у браузера провайдера нет (§«Поведение»).
    func provider(forAppKey appKey: String) -> String? {
        guard !isBrowser(appKey: appKey) else { return nil }
        let owner = clients.first { client in
            client.bundleIds.contains { bundleKeyMatches(appKey: appKey, entry: $0) }
        }
        return owner?.provider
    }

    /// Ключ совпал по §4.1 хотя бы с одной строкой `browsers` или `clients[].bundleIds`.
    func isKnownApplication(appKey: String) -> Bool {
        isBrowser(appKey: appKey) || provider(forAppKey: appKey) != nil
    }

    /// Инвариант 7: неизвестный провайдер — пустой массив.
    func clientBundleIds(for provider: String) -> [String] {
        clients.filter { $0.provider == provider }.flatMap(\.bundleIds)
    }

    /// Инвариант 8: объединение всех `clients[].bundleIds`, браузеров в нём нет.
    func allKnownClientBundleIds() -> [String] {
        var seen = Set<String>()
        return clients.flatMap(\.bundleIds).filter { seen.insert($0).inserted }
    }
}
