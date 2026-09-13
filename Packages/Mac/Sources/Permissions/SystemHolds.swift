//  SystemHolds — удержание системы от сна и от App Nap (C-008, инварианты 2–5).
//
//  Два системных ограничения: сон по бездействию — `IOPMAssertion` вида
//  `PreventUserIdleSystemSleep` (наблюдаемо через `IOPMCopyAssertionsByProcess`), App Nap —
//  `ProcessInfo.beginActivity(.background)`. `.recording` берёт оба, `.processing` — только
//  второе. Удержания считаются: системное берётся первым токеном и отпускается последним
//  (инвариант 4). Отказ системы не фатален: токен возвращается, факт отказа — только в логе.

import DomainCore
import Foundation
import IOKit.pwr_mgt
import os

enum SystemHold: Hashable, Sendable {
    case preventIdleSystemSleep
    case preventAppNap

    static func holds(for reason: PowerActivityReason) -> [SystemHold] {
        switch reason {
        case .recording: return [.preventIdleSystemSleep, .preventAppNap]
        case .processing: return [.preventAppNap]
        }
    }
}

protocol SystemHoldHandle: AnyObject {
    func release()
}

/// Шов 2: взятие системного удержания. Бросает, если система отказала.
protocol SystemHoldService: Sendable {
    func acquire(_ hold: SystemHold, label: String) throws -> SystemHoldHandle
}

struct HoldFailure: Error {
    let status: Int32
}

final class SystemHoldsService: SystemHoldService {

    func acquire(_ hold: SystemHold, label: String) throws -> SystemHoldHandle {
        switch hold {
        case .preventIdleSystemSleep:
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     label as CFString, &id)
            guard status == kIOReturnSuccess else { throw HoldFailure(status: status) }
            return AssertionHandle(id: id)
        case .preventAppNap:
            return ActivityHandle(ProcessInfo.processInfo.beginActivity(options: .background, reason: label))
        }
    }
}

final class AssertionHandle: SystemHoldHandle {

    private let id: IOPMAssertionID

    init(id: IOPMAssertionID) {
        self.id = id
    }

    func release() {
        IOPMAssertionRelease(id)
    }
}

final class ActivityHandle: SystemHoldHandle {

    private let activity: NSObjectProtocol

    init(_ activity: NSObjectProtocol) {
        self.activity = activity
    }

    func release() {
        ProcessInfo.processInfo.endActivity(activity)
    }
}

/// Счёт удержаний по видам: системное берётся на первом и отпускается на последнем.
final class HoldRegistry: @unchecked Sendable {

    private let service: SystemHoldService
    private let lock = NSLock()
    private var counts: [SystemHold: Int] = [:]
    private var handles: [SystemHold: SystemHoldHandle] = [:]
    private let log = Logger(subsystem: "meetforme.permissions", category: "power")

    init(service: SystemHoldService) {
        self.service = service
    }

    func acquire(_ hold: SystemHold, label: String) {
        lock.lock()
        defer { lock.unlock() }
        let count = (counts[hold] ?? 0) + 1
        counts[hold] = count
        guard count == 1 else { return }
        do {
            handles[hold] = try service.acquire(hold, label: label)
        } catch {
            log.error("удержание \(String(describing: hold)) не взято: \(String(describing: error))")
        }
    }

    func release(_ hold: SystemHold) {
        lock.lock()
        defer { lock.unlock() }
        guard let count = counts[hold], count > 0 else { return }
        if count > 1 {
            counts[hold] = count - 1
            return
        }
        counts[hold] = nil
        handles.removeValue(forKey: hold)?.release()
    }

    /// Какие системные удержания сейчас взяты — вход критериев 59, 60, 61 (шов 2).
    var activeSystemHolds: Set<SystemHold> {
        lock.lock()
        defer { lock.unlock() }
        return Set(handles.keys)
    }

    /// Число живых токенов, требующих удержания, — вход критерия 64.
    func liveCount(_ hold: SystemHold) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[hold] ?? 0
    }
}

/// Токен удержания: причина неизменяема, `end()` идемпотентен, освобождение объекта
/// снимает удержание (инварианты 2, 3, 5).
final class ActivityToken: PowerActivityToken, @unchecked Sendable {

    let reason: PowerActivityReason
    let label: String
    private let registry: HoldRegistry
    private let lock = NSLock()
    private var ended = false

    init(reason: PowerActivityReason, label: String, registry: HoldRegistry) {
        self.reason = reason
        self.label = label
        self.registry = registry
        for hold in SystemHold.holds(for: reason) {
            registry.acquire(hold, label: label)
        }
    }

    deinit {
        end()
    }

    func end() {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        guard first else { return }
        for hold in SystemHold.holds(for: reason) {
            registry.release(hold)
        }
    }
}
