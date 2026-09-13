//  SystemPermissions — реализация `PermissionsPort` (C-007) для приложения на Mac.
//
//  Единственный публичный тип этой стороны модуля: инвариант 10 требует хотя бы один
//  собственный публичный тип — реализацию связывает composition root приложения (`app-ui`), —
//  и больше наружу выводить нечего. Публичные сигнатуры несут только позиции разрешённого
//  списка инварианта 10. Правила и состояние — в `PermissionsCore`.

import DomainCore
import Foundation

/// Права приложения: статусы TCC, системные промпты, раздел настроек и автозапуск.
public final class SystemPermissions: PermissionsPort, Sendable {

    private let core: PermissionsCore
    private let environment: PermissionsCore.Environment

    /// Порт приложения: статусы читаются у системы, промпты показывает система.
    public convenience init() {
        self.init(environment: .system())
    }

    init(environment: PermissionsCore.Environment) {
        self.environment = environment
        let core = PermissionsCore(environment: environment)
        self.core = core
        environment.activation.start { [weak core] in
            guard let core else { return }
            Task { _ = await core.refresh() }
        }
    }

    deinit {
        environment.activation.stop()
        core.publisher.finishAll()
    }

    // MARK: - PermissionsPort

    public func snapshot() async -> PermissionSnapshot {
        await core.snapshot()
    }

    public func status(of kind: PermissionKind) async -> PermissionStatus {
        await core.status(of: kind)
    }

    public func request(_ kind: PermissionKind) async -> PermissionRequestOutcome {
        await core.request(kind)
    }

    public func openSettings(for kind: PermissionKind) async throws {
        try await core.openSettings(for: kind)
    }

    public func changes() -> AsyncStream<PermissionSnapshot> {
        core.publisher.stream()
    }

    public func note(observed: PermissionStatus, for kind: PermissionKind) async {
        await core.note(observed: observed, for: kind)
    }

    public func isLaunchAtLoginEnabled() async -> Bool {
        await core.isLaunchAtLoginEnabled()
    }

    public func setLaunchAtLogin(_ enabled: Bool) async throws {
        try await core.setLaunchAtLogin(enabled)
    }

    // MARK: - Внутреннее: для тестов модуля

    /// Число живых наблюдателей `changes()` — вход критерия 36.
    var liveObserverCount: Int {
        core.publisher.subscriberCount
    }
}
