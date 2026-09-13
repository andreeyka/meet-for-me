//  Критерии перечня MEE-74 на поток `events()` (C-008): 68, 70, 71 и механическая половина 69.
//  Уведомления подаёт тест (шов 2), значения — подставленное чтение; сравнение с последним
//  опубликованным и публикацию исполняет настоящий `PowerEngine`.

import DomainCore
import Foundation
import IOKit.ps
import XCTest
@testable import Permissions

final class PowerEventTests: XCTestCase {

    // MARK: - 68. Событие только при фактической смене значения — для каждого из трёх видов

    func test_c68_powerSourceChanged_onlyOnActualChange() async {
        let harness = PowerHarness()
        let stream = harness.sut.events()
        for _ in 0..<3 {
            harness.signals.fire(.powerSourcesDidChange)
        }
        harness.reader.set(source: kIOPMBatteryPowerKey)
        harness.signals.fire(.powerSourcesDidChange)
        let events = await Streams.take(stream, 2, within: 0.3)
        XCTAssertEqual(events, [.powerSourceChanged(.battery)])
    }

    func test_c68_thermalPressureChanged_onlyOnActualChange() async {
        let harness = PowerHarness()
        let stream = harness.sut.events()
        for _ in 0..<3 {
            harness.signals.fire(.thermalStateDidChange)
        }
        harness.reader.set(thermalState: .serious)
        harness.signals.fire(.thermalStateDidChange)
        let events = await Streams.take(stream, 2, within: 0.3)
        XCTAssertEqual(events, [.thermalPressureChanged(.serious)])
    }

    func test_c68_lowPowerModeChanged_onlyOnActualChange() async {
        let harness = PowerHarness()
        let stream = harness.sut.events()
        for _ in 0..<3 {
            harness.signals.fire(.powerStateDidChange)
        }
        harness.reader.set(lowPowerMode: true)
        harness.signals.fire(.powerStateDidChange)
        let events = await Streams.take(stream, 2, within: 0.3)
        XCTAssertEqual(events, [.lowPowerModeChanged(true)])
    }

    // MARK: - 69, механическая половина. Снимок согласован с событием

    func test_c69_snapshotAgreesWithPowerSourceChanged() async {
        let harness = PowerHarness()
        let stream = harness.sut.events()
        let steps: [(String?, PowerSource)] = [(kIOPMBatteryPowerKey, .battery), (kIOPMACPowerKey, .ac),
                                               (nil, .unknown)]
        for (type, expected) in steps {
            harness.reader.set(source: type)
            harness.signals.fire(.powerSourcesDidChange)
            let snapshot = await harness.sut.snapshot()
            XCTAssertEqual(snapshot.source, expected)
        }
        let events = await Streams.take(stream, 3)
        XCTAssertEqual(events, [.powerSourceChanged(.battery), .powerSourceChanged(.ac), .powerSourceChanged(.unknown)])
    }

    // MARK: - 70. Предыстории в потоке нет

    func test_c70_subscriptionGetsNoHistory() async {
        let harness = PowerHarness()
        harness.reader.set(source: kIOPMBatteryPowerKey)
        harness.signals.fire(.powerSourcesDidChange)
        let stream = harness.sut.events()
        let events = await Streams.take(stream, 1, within: 0.1)
        XCTAssertEqual(events, [])
    }

    // MARK: - 71. Три подписчика — одна последовательность в одном порядке

    func test_c71_threeSubscribers_sameSequence() async {
        let harness = PowerHarness()
        let streams = [harness.sut.events(), harness.sut.events(), harness.sut.events()]
        harness.signals.fire(.willSleep)
        harness.signals.fire(.didWake)
        harness.reader.set(source: kIOPMBatteryPowerKey)
        harness.signals.fire(.powerSourcesDidChange)
        harness.reader.set(thermalState: .fair)
        harness.signals.fire(.thermalStateDidChange)
        let expected: [PowerEvent] = [.willSleep, .didWake, .powerSourceChanged(.battery),
                                      .thermalPressureChanged(.fair)]
        for stream in streams {
            let events = await Streams.take(stream, 4)
            XCTAssertEqual(events, expected)
        }
    }

    // MARK: - Дисплей идёт своими событиями; переход на сон их не влечёт

    func test_screenEvents_passThroughUnchanged() async {
        let harness = PowerHarness()
        let stream = harness.sut.events()
        harness.signals.fire(.screensDidSleep)
        harness.signals.fire(.screensDidWake)
        let events = await Streams.take(stream, 3, within: 0.3)
        XCTAssertEqual(events, [.screensDidSleep, .screensDidWake])
    }
}
