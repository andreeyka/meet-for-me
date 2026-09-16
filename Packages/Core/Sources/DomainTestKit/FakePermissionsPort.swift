//  FakePermissionsPort — реализация `PermissionsPort` в памяти, C-007 §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Управляется тестом целиком: стартовый статус задаётся каждому `PermissionKind`, включая
//  `.unknown`; ответ `request(_:)` задаётся ОТДЕЛЬНО от статуса; в поток `changes()` толкается
//  любой `PermissionSnapshot`; `openSettings(for:)` заставляется бросить; вызовы `request`,
//  `openSettings` и `note` считаются ПО ПРАВАМ; `isLaunchAtLoginEnabled` переключается.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА, и граница названа здесь потому, что молчание о ней читается
//  как её отсутствие. Инварианты C-007 — обязанность реализатора `permissions`, проверяются его
//  тестами и фейком не проверяются никогда. Прямое следствие, ради которого фейк и существует:
//  ответ `request(_:)` НЕ ВЫВОДИТСЯ из заданного статуса, то есть вход, запрещённый инвариантами
//  3 и 4 порту, здесь проходит как есть. Реализация, выводящая ответ из статуса, зелена на всяком
//  согласованном векторе — и она же превращает фейк во второй источник истины помимо теста.
//
//  `note(observed:for:)` СЧИТАЕТСЯ И НЕ МЕНЯЕТ СОСТОЯНИЯ. Правило «какие права и какие значения
//  принимает `note`» есть инвариант 13, то есть обязанность порта; фейк, исполняющий его, молча
//  перекрывал бы заданный тестом статус. Тесту, которому нужен статус после `note`, он кладётся
//  тем же `setStatus(_:for:)` — ровно как `FixedPlatformResolver` кладёт ответ в словарь вместо
//  автоматического `unknown`.
//
//  Снимок, протолкнутый в `changes()`, состояния `snapshot()` не трогает — и это тоже граница,
//  а не упущение: связать их значило бы ответить за владельца C-007 на открытый вопрос о том,
//  вправе ли фейк отдать из `snapshot()` снимок, нарушающий инвариант 1. Обе стороны задаются
//  тестом порознь, и ни одна не выводится из другой.
//
//  `@unchecked Sendable` с замком, а не актор: `PermissionsPort` объявлен `: Sendable`, а его
//  методы — не `async` целиком (`changes()` синхронен), и актором протокол не покрыть.

import Foundation
import DomainCore

/// Фейк порта прав. Всё поведение задаёт тест.
public final class FakePermissionsPort: PermissionsPort, @unchecked Sendable {

    private let lock = NSLock()
    private var statuses: [PermissionKind: PermissionStatus] = [:]
    private var checkedAt: Date
    private var outcomes: [PermissionKind: PermissionRequestOutcome] = [:]
    private var settingsFailures: [PermissionKind: PermissionsError] = [:]
    private var continuations: [AsyncStream<PermissionSnapshot>.Continuation] = []
    private var requestCalls: [PermissionKind: Int] = [:]
    private var openSettingsCalls: [PermissionKind: Int] = [:]
    private var noteCalls: [PermissionKind: Int] = [:]
    private var launchAtLogin = false

    /// - Parameters:
    ///   - startingStatus: значение, которым засеяны ВСЕ шесть прав.
    ///   - startingOutcome: ответ `request(_:)`, которым засеяны ВСЕ шесть прав.
    ///   - checkedAt: `PermissionSnapshot.checkedAt`.
    ///
    /// Умолчаний у параметров нет намеренно. «Пустого» значения ни у статуса, ни у ответа
    /// `request` не существует — всякое из них есть утверждение, — и умолчание здесь было бы
    /// решением фейка вместо входа теста. `Date()` внутри фейка вдобавок сделал бы равенство
    /// снимков невоспроизводимым.
    public init(startingStatus: PermissionStatus,
                startingOutcome: PermissionRequestOutcome,
                checkedAt: Date) {
        self.checkedAt = checkedAt
        for kind in PermissionKind.allCases {
            statuses[kind] = startingStatus
            outcomes[kind] = startingOutcome
        }
    }

    /// Замок вокруг состояния. Своя обёртка, а не `NSLocking.withLock`: та пришла в Foundation
    /// позже минимальной версии тулчейна, на которой собирается работа CI `Core (Linux)`.
    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    /// Задать или сменить статус одного права.
    public func setStatus(_ status: PermissionStatus, for kind: PermissionKind) {
        locked { statuses[kind] = status }
    }

    /// Задать `checkedAt` будущих снимков.
    public func setCheckedAt(_ moment: Date) {
        locked { checkedAt = moment }
    }

    /// Задать, чем ответит `request(_:)` на это право. Со статусом ответ не связан ничем.
    public func setRequestOutcome(_ outcome: PermissionRequestOutcome, for kind: PermissionKind) {
        locked { outcomes[kind] = outcome }
    }

    /// Заставить `openSettings(for:)` бросить названную ошибку; `nil` снимает отказ.
    public func failOpenSettings(with error: PermissionsError?, for kind: PermissionKind) {
        locked { settingsFailures[kind] = error }
    }

    /// Протолкнуть снимок в поток `changes()`. Значение не приводится ни к чему и доходит как есть.
    public func emit(_ snapshot: PermissionSnapshot) {
        let targets = locked { continuations }
        for continuation in targets {
            continuation.yield(snapshot)
        }
    }

    /// Закрыть поток: подписчики досматривают выданное и выходят из цикла.
    public func finishChanges() {
        let targets = locked { () -> [AsyncStream<PermissionSnapshot>.Continuation] in
            let taken = continuations
            continuations = []
            return taken
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    /// Счётчик вызовов `request(_:)` по этому праву.
    public func requestCallCount(for kind: PermissionKind) -> Int {
        locked { requestCalls[kind] ?? 0 }
    }

    /// Счётчик вызовов `openSettings(for:)` по этому праву. Растёт и там, где вызов бросил.
    public func openSettingsCallCount(for kind: PermissionKind) -> Int {
        locked { openSettingsCalls[kind] ?? 0 }
    }

    /// Счётчик вызовов `note(observed:for:)` по этому праву.
    public func noteCallCount(for kind: PermissionKind) -> Int {
        locked { noteCalls[kind] ?? 0 }
    }

    // MARK: - PermissionsPort

    public func snapshot() async -> PermissionSnapshot {
        locked { () -> PermissionSnapshot in
            let states = PermissionKind.allCases.map {
                PermissionState(kind: $0, status: statuses[$0] ?? .unknown)
            }
            return PermissionSnapshot(states: states, checkedAt: checkedAt)
        }
    }

    /// `?? .unknown` недостижимо по построению (засев в `init` тотален) и стоит по тому же
    /// доводу, что и в `request(_:)`.
    public func status(of kind: PermissionKind) async -> PermissionStatus {
        locked { statuses[kind] ?? .unknown }
    }

    /// Отдаёт ЗАДАННЫЙ ответ, а не выведенный из статуса.
    ///
    /// Развилка `?? .cannotPrompt` недостижима по построению: засев в `init` кладёт ответ
    /// каждому из шести прав, а `setRequestOutcome` только заменяет. Она стоит здесь по тому же
    /// доводу, по которому `PermissionSnapshot.status(of:)` отвечает на недостижимый вход:
    /// ловушка превратила бы красный тест в крэш без сообщения.
    public func request(_ kind: PermissionKind) async -> PermissionRequestOutcome {
        locked { () -> PermissionRequestOutcome in
            requestCalls[kind, default: 0] += 1
            return outcomes[kind] ?? .cannotPrompt
        }
    }

    public func openSettings(for kind: PermissionKind) async throws {
        let failure = locked { () -> PermissionsError? in
            openSettingsCalls[kind, default: 0] += 1
            return settingsFailures[kind]
        }
        if let failure {
            throw failure
        }
    }

    public func changes() -> AsyncStream<PermissionSnapshot> {
        AsyncStream { continuation in
            locked { continuations.append(continuation) }
        }
    }

    public func note(observed: PermissionStatus, for kind: PermissionKind) async {
        locked { noteCalls[kind, default: 0] += 1 }
    }

    public func isLaunchAtLoginEnabled() async -> Bool {
        locked { launchAtLogin }
    }

    /// Не бросает ни на одном входе: способа заставить его бросить §«Фейк для тестов» C-007
    /// не даёт ни одним словом, а завести такой способ здесь значило бы ответить за владельца
    /// контракта. Ветка `loginItemRegistrationFailed` остаётся непокрытой, и это названо.
    public func setLaunchAtLogin(_ enabled: Bool) async throws {
        locked { launchAtLogin = enabled }
    }
}
