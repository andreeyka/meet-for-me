//  PowerEngine — снимок, поток событий и удержания `PowerPort` (C-008).
//
//  Точка отсчёта для событий смены значения читается при создании: событие идёт в поток только
//  при фактической смене относительно последнего опубликованного (инвариант 7), и снимок после
//  `.powerSourceChanged(x)` читает у системы то же `x` (инвариант 8). Сон, пробуждение и дисплей
//  публикуются как пришли; `.willSleep` порт не задерживает и удержаний после `.didWake` сам
//  не берёт («Поведение»).

import DomainCore
import Foundation

final class PowerEngine: @unchecked Sendable {

    struct Environment: Sendable {
        let reader: PowerReader
        let signals: PowerSignalSource
        let holds: SystemHoldService

        static func system() -> Environment {
            Environment(reader: SystemPowerReader(), signals: SystemPowerSignals(), holds: SystemHoldsService())
        }
    }

    let holds: HoldRegistry
    private let environment: Environment
    private let publisher = Broadcaster<PowerEvent>()
    private let lock = NSLock()
    private var lastSource: PowerSource
    private var lastThermalPressure: ThermalPressure
    private var lastLowPowerMode: Bool

    init(environment: Environment) {
        self.environment = environment
        holds = HoldRegistry(service: environment.holds)
        let reading = environment.reader.read()
        lastSource = PowerTranslation.source(reading.providingSourceType)
        lastThermalPressure = PowerTranslation.thermalPressure(reading.thermalState)
        lastLowPowerMode = reading.isLowPowerModeEnabled
        environment.signals.start { [weak self] signal in self?.handle(signal) }
    }

    deinit {
        environment.signals.stop()
        publisher.finishAll()
    }

    func snapshot() -> PowerSnapshot {
        PowerTranslation.snapshot(environment.reader.read(), at: Date())
    }

    func events() -> AsyncStream<PowerEvent> {
        publisher.stream()
    }

    func beginActivity(reason: PowerActivityReason, label: String) -> PowerActivityToken {
        ActivityToken(reason: reason, label: label, registry: holds)
    }

    private func handle(_ signal: PowerSignal) {
        switch signal {
        case .willSleep: publisher.send(.willSleep)
        case .didWake: publisher.send(.didWake)
        case .screensDidSleep: publisher.send(.screensDidSleep)
        case .screensDidWake: publisher.send(.screensDidWake)
        case .powerSourcesDidChange, .thermalStateDidChange, .powerStateDidChange: publishValueChanges()
        }
    }

    /// Перечитать три значения и опубликовать событие на каждое, что сменилось.
    private func publishValueChanges() {
        let reading = environment.reader.read()
        let source = PowerTranslation.source(reading.providingSourceType)
        let thermalPressure = PowerTranslation.thermalPressure(reading.thermalState)
        lock.lock()
        defer { lock.unlock() }
        if source != lastSource {
            lastSource = source
            publisher.send(.powerSourceChanged(source))
        }
        if thermalPressure != lastThermalPressure {
            lastThermalPressure = thermalPressure
            publisher.send(.thermalPressureChanged(thermalPressure))
        }
        if reading.isLowPowerModeEnabled != lastLowPowerMode {
            lastLowPowerMode = reading.isLowPowerModeEnabled
            publisher.send(.lowPowerModeChanged(reading.isLowPowerModeEnabled))
        }
    }
}
