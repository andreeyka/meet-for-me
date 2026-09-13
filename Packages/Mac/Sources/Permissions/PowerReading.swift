//  PowerReading — исход системного чтения питания и тепла и его перевод в типы C-008.
//
//  Перевод — чистая функция; тест сопоставляет `thermalPressure` с `ProcessInfo` по этой же
//  таблице (критерий 53). Решения, которых контракт не называет:
//
//  * источник «UPS Power» → `.battery`: машина питается не от сети, и для `JobQueue` это тот же
//    сигнал, что батарея; всё, чего система не назвала, → `.unknown`;
//  * тепловое состояние, которого перечисление `ProcessInfo.ThermalState` сегодня не знает,
//    → `.critical`: неизмеренное состояние безопаснее считать худшим — обработка подождёт,
//    чем греть машину под неизвестным режимом;
//  * ёмкость батареи с недостоверным максимумом (≤ 0) считается нечитаемой: батарея есть,
//    доля неизвестна — отдаётся `nil`. Это единственное место, где «`nil` ⟺ батареи нет»
//    нарушается, и оно названо.

import DomainCore
import Foundation
import IOKit.ps

struct BatteryCapacity: Equatable, Sendable {
    let current: Int
    let maximum: Int
}

/// Ровно то, что отдали `IOPSGetProvidingPowerSourceType`, описание встроенной батареи и
/// `ProcessInfo` (шов 2, сторона C-008 — подставляется в тесте).
struct PowerReading: Equatable, Sendable {
    let providingSourceType: String?
    let internalBattery: BatteryCapacity?
    let isLowPowerModeEnabled: Bool
    let thermalState: ProcessInfo.ThermalState
}

enum PowerTranslation {

    static func snapshot(_ reading: PowerReading, at moment: Date) -> PowerSnapshot {
        PowerSnapshot(source: source(reading.providingSourceType),
                      batteryFraction: batteryFraction(reading.internalBattery),
                      isLowPowerModeEnabled: reading.isLowPowerModeEnabled,
                      thermalPressure: thermalPressure(reading.thermalState),
                      checkedAt: moment)
    }

    static func source(_ providingSourceType: String?) -> PowerSource {
        switch providingSourceType {
        case kIOPMACPowerKey: return .ac
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: return .battery
        default: return .unknown
        }
    }

    static func batteryFraction(_ capacity: BatteryCapacity?) -> Double? {
        guard let capacity, capacity.maximum > 0 else { return nil }
        return min(max(Double(capacity.current) / Double(capacity.maximum), 0), 1)
    }

    static func thermalPressure(_ state: ProcessInfo.ThermalState) -> ThermalPressure {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }
}
