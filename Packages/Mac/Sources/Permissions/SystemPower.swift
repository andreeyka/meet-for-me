//  SystemPower — реализация `PowerPort` (C-008) для приложения на Mac.
//
//  Второй и последний публичный тип модуля (см. `SystemPermissions`). Публичные сигнатуры
//  несут только позиции разрешённого списка инварианта 10; правила и состояние — в `PowerEngine`.

import DomainCore
import Foundation

/// Питание, сон и тепло машины; удержание системы от сна и от App Nap.
public final class SystemPower: PowerPort, Sendable {

    private let engine: PowerEngine

    /// Порт приложения: питание читается у IOKit, события — у системы.
    public convenience init() {
        self.init(environment: .system())
    }

    init(environment: PowerEngine.Environment) {
        engine = PowerEngine(environment: environment)
    }

    // MARK: - PowerPort

    public func snapshot() async -> PowerSnapshot {
        engine.snapshot()
    }

    public func events() -> AsyncStream<PowerEvent> {
        engine.events()
    }

    public func beginActivity(reason: PowerActivityReason, label: String) async -> PowerActivityToken {
        engine.beginActivity(reason: reason, label: label)
    }

    // MARK: - Внутреннее: для тестов модуля

    /// Удержания, взятые модулем, — вход критериев 59, 60, 61, 64.
    var holds: HoldRegistry {
        engine.holds
    }
}
