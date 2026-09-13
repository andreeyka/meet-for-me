//  SystemPowerReader — чтение питания у IOKit и тепла у `ProcessInfo`. Единственное место
//  модуля, которое говорит с системой о питании.

import Foundation
import IOKit.ps

protocol PowerReader: Sendable {
    func read() -> PowerReading
}

final class SystemPowerReader: PowerReader {

    func read() -> PowerReading {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return PowerReading(providingSourceType: providing,
                            internalBattery: Self.internalBattery(info),
                            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                            thermalState: ProcessInfo.processInfo.thermalState)
    }

    /// Первая встроенная батарея в списке источников; `nil`, если её нет.
    private static func internalBattery(_ info: CFTypeRef) -> BatteryCapacity? {
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int else { continue }
            return BatteryCapacity(current: current, maximum: maximum)
        }
        return nil
    }
}
