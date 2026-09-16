//  PermissionsPort — контракт C-007 (MEE-11), раздел «Определение»
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-86). Реализацию порта пишет модуль `permissions`
//  (Packages/Mac/Sources/Permissions/); фейк `FakePermissionsPort` лежит в соседнем таргете
//  этого пакета — Packages/Core/Sources/DomainTestKit/.
//
//  Порядок типов и порядок полей внутри типа — дословно по §«Определение» контракта.
//  Порядок полей значим: на нём стоит правило обхода C-001 §0.2 п. 9 (ступени (а) и (в) идут
//  по полям в порядке объявления), и перестановка меняет ответ, а не только вид текста.

import Foundation

public enum PermissionKind: String, Codable, Sendable, CaseIterable {
    case microphone             // микрофонный канал записи
    case systemAudioRecording   // «System Audio Recording Only» — process taps
    case screenRecording        // «Screen & System Audio Recording» — только для запасного пути захвата
    case calendars              // полный доступ к календарям для in-process коннектора
    case notifications          // уведомления «начать запись?»
    case accessibility          // заголовки окон; опционально, вне Среза 1 по функциональности
}

public enum PermissionStatus: String, Codable, Sendable {
    case notDetermined   // системный промпт ещё не показывался
    case granted
    case denied          // пользователь отказал; повторный промпт система не покажет
    case restricted      // запрещено политикой устройства, пользователь изменить не может
    case unavailable     // эта версия macOS такой категории права не имеет
    // система не отдаёт статус этой категории; см. §«Права, статус которых система не отдаёт»
    case unknown
}

public enum PermissionRequestOutcome: String, Codable, Sendable {
    case granted
    case denied
    case cannotPrompt    // промпт невозможен; остаётся openSettings(for:)
    // промпт покажет система в момент фактического использования права; порт показать его не может
    case promptOnUse
}

public struct PermissionState: Codable, Equatable, Sendable {
    public let kind: PermissionKind
    public let status: PermissionStatus

    public init(kind: PermissionKind, status: PermissionStatus) {
        self.kind = kind
        self.status = status
    }
}

public struct PermissionSnapshot: Codable, Equatable, Sendable {
    public let states: [PermissionState]
    public let checkedAt: Date

    public init(states: [PermissionState], checkedAt: Date) {
        self.states = states
        self.checkedAt = checkedAt
    }

    /// Статус права в этом снимке.
    ///
    /// Для `kind`, отсутствующего в `states`, возвращает `.unknown` и **не роняет процесс**.
    /// Случай недостижим у верной реализации: инвариант 1 требует в снимке ровно по одному
    /// элементу на каждое значение `PermissionKind.allCases`. Достижим он только у снимка,
    /// собранного тестом или сломанной реализацией, — и там ответ обязан быть определён:
    /// метод с ловушкой превращает красный тест в крэш без сообщения.
    ///
    /// Почему именно `.unknown` (решение владельца модуля, MEE-86, критерий 5): это единственное
    /// значение перечисления, которое не утверждает о праве ничего. По §«Что `.unknown` означает
    /// и чего не означает» из него нельзя заключить ни «право есть», ни «права нет», и мастер прав
    /// не вправе нарисовать по нему ни «разрешено», ни «запрещено», — а состояния для этого `kind`
    /// у снимка и правда нет. `.notDetermined` солгал бы «промпт не показывался» и повёл бы
    /// мастер прав к кнопке «запросить»; `.denied` и `.restricted` назвали бы причину отказа,
    /// которой не было; `.unavailable` — отсутствие категории в этой версии macOS.
    ///
    /// Инвариант 11 («`.unknown` ни для какого другого `kind` не возникает никогда») этим
    /// не затронут: он говорит о `status(of:)` **порта**, чей снимок полон по инварианту 1,
    /// и достижимого входа, на котором порт вернул бы отсюда `.unknown`, не существует.
    public func status(of kind: PermissionKind) -> PermissionStatus {
        states.first { $0.kind == kind }?.status ?? .unknown
    }
}

public enum PermissionsError: Error, Codable, Equatable, Sendable {
    case loginItemRegistrationFailed(message: String)
    case settingsPaneUnavailable(kind: PermissionKind)
}

public protocol PermissionsPort: Sendable {
    func snapshot() async -> PermissionSnapshot
    func status(of kind: PermissionKind) async -> PermissionStatus
    func request(_ kind: PermissionKind) async -> PermissionRequestOutcome
    func openSettings(for kind: PermissionKind) async throws
    func changes() -> AsyncStream<PermissionSnapshot>

    /// Сообщить порту статус, наблюдённый стороной, которая фактически выполняла операцию,
    /// требующую права. Для прав, статус которых система не отдаёт, это единственный источник
    /// значения, отличного от `.unknown`.
    func note(observed: PermissionStatus, for kind: PermissionKind) async

    // Автозапуск — не право TCC, но тот же модуль-реализатор.
    func isLaunchAtLoginEnabled() async -> Bool
    func setLaunchAtLogin(_ enabled: Bool) async throws
}
