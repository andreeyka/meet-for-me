//  Критерии перечня MEE-74 на снимок `PowerPort` (C-008): 51, 52, 53, 54, 72 — на настоящем
//  чтении у системы; таблица перевода — на подставленном.

import DomainCore
import Foundation
import IOKit.ps
import XCTest
@testable import Permissions

final class PowerSnapshotTests: XCTestCase {

    // MARK: - 51. batteryFraction — nil либо в 0...1, десять раз подряд

    func test_c51_batteryFraction_nilOrUnitInterval() async {
        let sut = SystemPower()
        for _ in 0..<10 {
            let snapshot = await sut.snapshot()
            if let fraction = snapshot.batteryFraction {
                XCTAssertTrue((0...1).contains(fraction), "\(fraction)")
            }
        }
    }

    // MARK: - 52. nil тогда и только тогда, когда встроенной батареи нет — обе половины на этой машине

    func test_c52_batteryFractionNil_iffNoInternalBattery() async {
        let snapshot = await SystemPower().snapshot()
        let hasBattery = Self.internalBatteryPresent()
        let fraction = String(describing: snapshot.batteryFraction)
        let battery = hasBattery ? "есть" : "отсутствует"
        XCTAssertEqual(snapshot.batteryFraction == nil, !hasBattery, "батарея \(battery), доля \(fraction)")
        print("c52: встроенная батарея \(battery), batteryFraction = \(fraction)")
    }

    private static func internalBatteryPresent() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    // MARK: - 53. thermalPressure совпадает с ProcessInfo по таблице реализации

    func test_c53_thermalPressure_matchesProcessInfo() async {
        let snapshot = await SystemPower().snapshot()
        XCTAssertEqual(snapshot.thermalPressure, PowerTranslation.thermalPressure(ProcessInfo.processInfo.thermalState))
        XCTAssertTrue([.nominal, .fair, .serious, .critical].contains(snapshot.thermalPressure))
    }

    // MARK: - 54. source из перечисления, isLowPowerModeEnabled — Bool, checkedAt — момент вызова

    func test_c54_sourceAndCheckedAt() async {
        let before = Date()
        let snapshot = await SystemPower().snapshot()
        let after = Date()
        XCTAssertTrue([.ac, .battery, .unknown].contains(snapshot.source))
        XCTAssertEqual(snapshot.isLowPowerModeEnabled, ProcessInfo.processInfo.isLowPowerModeEnabled)
        XCTAssertGreaterThanOrEqual(snapshot.checkedAt, before)
        XCTAssertLessThanOrEqual(snapshot.checkedAt, after)
    }

    // MARK: - 72. Порт вызывается из любого контекста

    func test_c72_calledFromDetachedTask() async {
        let sut = SystemPower()
        let onMain = await sut.snapshot()
        let detached = Task.detached { () -> PowerSnapshot in
            let token = await sut.beginActivity(reason: .processing, label: "c72")
            XCTAssertEqual(token.label, "c72")
            token.end()
            let stream = sut.events()
            XCTAssertNotNil(stream)
            return await sut.snapshot()
        }
        let snapshot = await detached.value
        XCTAssertEqual(snapshot.source, onMain.source)
        XCTAssertEqual(snapshot.batteryFraction == nil, onMain.batteryFraction == nil)
        XCTAssertEqual(snapshot.thermalPressure, onMain.thermalPressure)
    }

    // MARK: - Таблица перевода питания

    func test_powerTranslation_table() {
        XCTAssertEqual(PowerTranslation.source(kIOPMACPowerKey), .ac)
        XCTAssertEqual(PowerTranslation.source(kIOPMBatteryPowerKey), .battery)
        XCTAssertEqual(PowerTranslation.source(kIOPMUPSPowerKey), .battery)
        XCTAssertEqual(PowerTranslation.source(nil), .unknown)
        XCTAssertEqual(PowerTranslation.source("Off Line"), .unknown)
        XCTAssertNil(PowerTranslation.batteryFraction(nil))
        XCTAssertEqual(PowerTranslation.batteryFraction(BatteryCapacity(current: 50, maximum: 100)), 0.5)
        XCTAssertEqual(PowerTranslation.batteryFraction(BatteryCapacity(current: 120, maximum: 100)), 1)
        XCTAssertNil(PowerTranslation.batteryFraction(BatteryCapacity(current: 1, maximum: 0)))
        XCTAssertEqual(PowerTranslation.thermalPressure(.nominal), .nominal)
        XCTAssertEqual(PowerTranslation.thermalPressure(.fair), .fair)
        XCTAssertEqual(PowerTranslation.thermalPressure(.serious), .serious)
        XCTAssertEqual(PowerTranslation.thermalPressure(.critical), .critical)
        let reading = PowerReading(providingSourceType: kIOPMBatteryPowerKey,
                                   internalBattery: BatteryCapacity(current: 25, maximum: 100),
                                   isLowPowerModeEnabled: true, thermalState: .fair)
        let moment = Date()
        let snapshot = PowerTranslation.snapshot(reading, at: moment)
        XCTAssertEqual(snapshot, PowerSnapshot(source: .battery, batteryFraction: 0.25, isLowPowerModeEnabled: true,
                                               thermalPressure: .fair, checkedAt: moment))
    }
}
