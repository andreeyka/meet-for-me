//  PermissionsCore — состояние и правила `PermissionsPort` (C-007). Актор: вызовы порта
//  исполняются по одному, параллельные `request` одного права ждут один исход («Поведение»).
//
//  * Значение, принятое через `note`, живёт только здесь, в памяти процесса (инвариант 14):
//    новый экземпляр начинает с `.unknown`, на диск не пишется ничего.
//  * `changes()` публикует снимок только при фактическом изменении состояний (инвариант 8):
//    сравнивается с последним прочитанным снимком; первое чтение задаёт точку отсчёта и в поток
//    не идёт — начальное состояние читается через `snapshot()` («Поведение»). Принятый `note`
//    и исход промпта публикуются всегда: они меняют состояние сами.
//  * Перечитывания идут цепочкой, чтобы два одновременных не перемешали порядок снимков.

import DomainCore
import Foundation

actor PermissionsCore {

    struct Environment: Sendable {
        let rights: StatusSource
        let settings: SettingsOpener
        let loginItems: LoginItemRegistry
        let activation: ActivationSource
        /// MEE-379 (аудит MEE-377, возврат РП 24.09 18:05): шов часов — `checkedAt` снимка
        /// перестаёт быть настоящим `Date()`, недостижимым для тестов без реальной паузы.
        /// Значение по умолчанию сохраняет прежнее поведение для всех прежних мест вызова.
        let now: @Sendable () -> Date = Date.init

        static func system() -> Environment {
            Environment(rights: TranslatingStatusSource(reader: SystemRightsReader()),
                        settings: SystemSettingsOpener(),
                        loginItems: SystemLoginItems(),
                        activation: AppActivationSource())
        }
    }

    private let environment: Environment
    nonisolated let publisher = Broadcaster<PermissionSnapshot>()

    /// Статусы, принятые через `note` — только для прав, статус которых система не отдаёт.
    private var observed: [PermissionKind: PermissionStatus] = [:]
    private var lastStates: [PermissionState]?
    private var pendingPublish = false
    private var refreshChain: Task<PermissionSnapshot, Never>?
    private var requestsInFlight: [PermissionKind: Task<PermissionRequestOutcome, Never>] = [:]
    /// MEE-379 (аудит MEE-377, возврат РП 24.09 18:05): тестовый шов — сколько раз `request`
    /// присоединился к уже летящему запросу (не завёл свой). Поведение `request` не меняется;
    /// используется только тестом, ждущим этого факта вместо угадывания по времени.
    private(set) var joinedInFlightRequestCount = 0

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: - Чтение

    func status(of kind: PermissionKind) async -> PermissionStatus {
        if RightsCatalog.withoutSystemStatus.contains(kind) {
            return observed[kind] ?? .unknown
        }
        return await environment.rights.status(of: kind)
    }

    func snapshot() async -> PermissionSnapshot {
        await refresh()
    }

    /// Перечитать все права; опубликовать снимок, если состояния изменились.
    func refresh() async -> PermissionSnapshot {
        let previous = refreshChain
        let task = Task { [self] in
            _ = await previous?.value
            return await self.performRefresh()
        }
        refreshChain = task
        return await task.value
    }

    private func performRefresh() async -> PermissionSnapshot {
        var states: [PermissionState] = []
        for kind in PermissionKind.allCases {
            states.append(PermissionState(kind: kind, status: await status(of: kind)))
        }
        let snapshot = PermissionSnapshot(states: states, checkedAt: environment.now())
        let changed = pendingPublish || lastStates.map { $0 != states } ?? false
        pendingPublish = false
        lastStates = states
        if changed {
            publisher.send(snapshot)
        }
        return snapshot
    }

    // MARK: - Запрос

    func request(_ kind: PermissionKind) async -> PermissionRequestOutcome {
        if let inFlight = requestsInFlight[kind] {
            joinedInFlightRequestCount += 1
            return await inFlight.value
        }
        let task = Task { [self] in await self.performRequest(kind) }
        requestsInFlight[kind] = task
        let outcome = await task.value
        requestsInFlight[kind] = nil
        return outcome
    }

    private func performRequest(_ kind: PermissionKind) async -> PermissionRequestOutcome {
        let before = await status(of: kind)
        switch before {
        case .granted:
            return .granted
        case .denied, .restricted, .unavailable:
            return .cannotPrompt
        case .unknown:
            return .promptOnUse
        case .notDetermined:
            guard RightsCatalog.hasSystemPrompt(kind) else { return .cannotPrompt }
            let granted = await environment.rights.prompt(kind)
            if await status(of: kind) != before {
                pendingPublish = true
            }
            _ = await refresh()
            return granted ? .granted : .denied
        }
    }

    // MARK: - Наблюдённый факт

    func note(observed status: PermissionStatus, for kind: PermissionKind) async {
        guard RightsCatalog.withoutSystemStatus.contains(kind),
              status == .granted || status == .denied,
              observed[kind] != status else { return }
        observed[kind] = status
        pendingPublish = true
        _ = await refresh()
    }

    // MARK: - Настройки и автозапуск

    func openSettings(for kind: PermissionKind) async throws {
        guard await environment.settings.open(kind) else {
            throw PermissionsError.settingsPaneUnavailable(kind: kind)
        }
    }

    func isLaunchAtLoginEnabled() -> Bool {
        environment.loginItems.isEnabled()
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        do {
            try environment.loginItems.setEnabled(enabled)
        } catch {
            throw PermissionsError.loginItemRegistrationFailed(message: Self.message(of: error))
        }
    }

    private static func message(of error: Error) -> String {
        let text = error.localizedDescription
        return text.isEmpty ? String(describing: error) : text
    }
}
