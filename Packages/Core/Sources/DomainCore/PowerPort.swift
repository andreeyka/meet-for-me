//  PowerPort — контракт C-008 v1 (MEE-12), раздел «Определение»
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-86). Реализацию порта пишет модуль `permissions`
//  (Packages/Mac/Sources/Permissions/), фейк `FakePowerPort` придёт отдельным пакетом DEV-2.
//
//  Порядок типов и порядок полей внутри типа — дословно по §«Определение» контракта
//  (порядок значим: правило обхода C-001 §0.2 п. 9).

import Foundation

public enum PowerSource: String, Codable, Sendable {
    case ac        // питание от сети
    case battery
    case unknown   // источник определить не удалось
}

public enum ThermalPressure: String, Codable, Sendable {
    case nominal, fair, serious, critical
}

public struct PowerSnapshot: Codable, Equatable, Sendable {
    public let source: PowerSource
    public let batteryFraction: Double?          // 0...1; nil, если батареи в машине нет
    public let isLowPowerModeEnabled: Bool
    public let thermalPressure: ThermalPressure
    public let checkedAt: Date

    public init(
        source: PowerSource,
        batteryFraction: Double?,
        isLowPowerModeEnabled: Bool,
        thermalPressure: ThermalPressure,
        checkedAt: Date
    ) {
        self.source = source
        self.batteryFraction = batteryFraction
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalPressure = thermalPressure
        self.checkedAt = checkedAt
    }
}

public enum PowerEvent: Equatable, Sendable {
    case willSleep                               // система засыпает
    case didWake                                 // система проснулась
    case screensDidSleep                         // погас дисплей; система при этом не спит
    case screensDidWake
    case powerSourceChanged(PowerSource)
    case thermalPressureChanged(ThermalPressure)
    case lowPowerModeChanged(Bool)
}

public enum PowerActivityReason: String, Codable, Sendable {
    case recording    // идёт запись: запрещены и сон по бездействию, и App Nap
    case processing   // фоновая обработка: запрещён App Nap, сон по бездействию разрешён
}

public protocol PowerActivityToken: AnyObject, Sendable {
    var reason: PowerActivityReason { get }
    var label: String { get }
    func end()
}

public protocol PowerPort: Sendable {
    func snapshot() async -> PowerSnapshot
    func events() -> AsyncStream<PowerEvent>
    func beginActivity(reason: PowerActivityReason, label: String) async -> PowerActivityToken
}
