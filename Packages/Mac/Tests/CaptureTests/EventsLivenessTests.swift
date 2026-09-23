//  К25 — живучесть events(): один подписчик переживает несколько сеансов подряд без
//  переподписки, поток не закрывается на `stopped`. План MEE-315.
//
//  Вторая половина критерия (levels не чаще 10 Гц) в этой части не закрыта: порт сегодня не
//  публикует `.levels` вовсе — находка, названа в отчёте, а не решена молча (индикатор для
//  интерфейса вне зоны трёх частей этой задачи, ни один критерий MEE-310 кроме этой половины
//  К25 его не требует).

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class EventsLivenessTests: CaptureAsyncTestCase {

    func test_k25_oneSubscriberSeesEventsFromTwoConsecutiveSessionsWithoutResubscribing() async throws {
        let harness = Harness()
        let firstDirectory = try Harness.makeDirectory()
        let secondDirectory = try Harness.makeDirectory()

        // Считаем только started/stopped: успешный старт публикует ещё и permissionObserved
        // (право системного звука) — если считать вперемешку, «первые 4 события» не обязательно
        // окажутся двумя парами started/stopped.
        let collector = Task { () -> [CaptureEvent] in
            var collected: [CaptureEvent] = []
            var startedStoppedCount = 0
            for await event in harness.port.events() {
                collected.append(event)
                switch event {
                case .started, .stopped: startedStoppedCount += 1
                default: break
                }
                if startedStoppedCount >= 4 { break } // started, stopped × 2 сеанса
            }
            return collected
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        try await harness.start(directory: firstDirectory)
        _ = try await harness.port.stop()
        try await harness.start(directory: secondDirectory)
        _ = try await harness.port.stop()

        let events = await collector.value
        let startedCount = events.filter { if case .started = $0 { return true }; return false }.count
        let stoppedCount = events.filter { if case .stopped = $0 { return true }; return false }.count
        XCTAssertEqual(startedCount, 2, "оба сеанса дошли до одного и того же подписчика")
        XCTAssertEqual(stoppedCount, 2, "поток не закрылся на первом stopped")
    }
}
