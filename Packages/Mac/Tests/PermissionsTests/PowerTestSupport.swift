//  Оснастка тестов стороны C-008: фейки чтения питания, системных уведомлений и удержаний
//  (шов 2), сборка `SystemPower` на подставленных источниках и чтение удержаний процесса
//  глазами системы.

import DomainCore
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import XCTest
@testable import Permissions

// MARK: - Шов 2, сторона C-008: питание, уведомления, удержания

final class FakePowerReader: PowerReader, @unchecked Sendable {

    static let onMains = PowerReading(providingSourceType: kIOPMACPowerKey,
                                      internalBattery: BatteryCapacity(current: 50, maximum: 100),
                                      isLowPowerModeEnabled: false, thermalState: .nominal)

    private let lock = NSLock()
    private var reading: PowerReading

    init(_ reading: PowerReading = FakePowerReader.onMains) {
        self.reading = reading
    }

    func set(_ reading: PowerReading) {
        lock.lock()
        defer { lock.unlock() }
        self.reading = reading
    }

    func set(source: String?) {
        set(PowerReading(providingSourceType: source, internalBattery: reading.internalBattery,
                         isLowPowerModeEnabled: reading.isLowPowerModeEnabled, thermalState: reading.thermalState))
    }

    func set(thermalState: ProcessInfo.ThermalState) {
        set(PowerReading(providingSourceType: reading.providingSourceType, internalBattery: reading.internalBattery,
                         isLowPowerModeEnabled: reading.isLowPowerModeEnabled, thermalState: thermalState))
    }

    func set(lowPowerMode: Bool) {
        set(PowerReading(providingSourceType: reading.providingSourceType, internalBattery: reading.internalBattery,
                         isLowPowerModeEnabled: lowPowerMode, thermalState: reading.thermalState))
    }

    func read() -> PowerReading {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }
}

final class FakePowerSignals: PowerSignalSource, @unchecked Sendable {

    private let lock = NSLock()
    private var handler: (@Sendable (PowerSignal) -> Void)?

    func start(_ handler: @escaping @Sendable (PowerSignal) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
    }

    /// Подать системное уведомление; возврат означает, что порт его уже обработал.
    func fire(_ signal: PowerSignal) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(signal)
    }
}

final class FakeHoldHandle: SystemHoldHandle {

    private let onRelease: () -> Void

    init(onRelease: @escaping () -> Void) {
        self.onRelease = onRelease
    }

    func release() {
        onRelease()
    }
}

/// Отказывающая система: удержать не удаётся никогда (критерий 55).
final class FailingHoldService: SystemHoldService {

    func acquire(_ hold: SystemHold, label: String) throws -> SystemHoldHandle {
        throw HoldFailure(status: -1)
    }
}

struct PowerHarness {

    let reader: FakePowerReader
    let signals = FakePowerSignals()
    let sut: SystemPower

    init(reading: PowerReading = FakePowerReader.onMains, holds: SystemHoldService = SystemHoldsService()) {
        reader = FakePowerReader(reading)
        sut = SystemPower(environment: .init(reader: reader, signals: signals, holds: holds))
    }
}

// MARK: - Удержания процесса глазами системы

enum PowerAssertions {

    static let preventIdleSleep = "PreventUserIdleSystemSleep"
    /// Ключи записи удержания в ответе `IOPMCopyAssertionsByProcess` — как их печатает система.
    static let typeKeys = ["AssertionTrueType", "AssertType"]

    /// Удержания процесса по `IOPMCopyAssertionsByProcess`; пустой список — удержаний нет.
    static func assertions(of pid: Int32) -> [[String: Any]] {
        var dictionary: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dictionary) == kIOReturnSuccess,
              let byPid = dictionary?.takeRetainedValue() as NSDictionary? else { return [] }
        for (key, value) in byPid {
            guard let owner = key as? Int, owner == Int(pid) else { continue }
            return value as? [[String: Any]] ?? []
        }
        return []
    }

    static func holdsPreventIdleSleep(_ pid: Int32 = getpid()) -> Bool {
        assertions(of: pid).contains { entry in
            typeKeys.contains { entry[$0] as? String == preventIdleSleep }
        }
    }
}
