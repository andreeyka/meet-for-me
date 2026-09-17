//  Время параметром и вход машины — К10—К15.
//  MEE-298, часть A. Пункты плана MEE-288 §3, разделы Б и В, часть 2/8.
//
//  Из пяти сроков контракта часть A несёт четыре: `armAt`, `askAt`, `e.start`,
//  `graceEndsAt`. Пятый — срок §8.4 — наступает только в `recording`, и это часть B задачи.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineTimeTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К10 (инв. 14, первая половина)

    /// Переход не наступает ни на одном `tick` с `now`, меньшим срока, — сколько бы их ни
    /// было подряд. Несколько `tick` в векторе несущи: реализация, взводящая «почти в срок»,
    /// на одном `tick` неотличима от верной.
    func test_k10_noDeadlineFiresBeforeItsMoment() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        // armAt = T − 600, askAt = T − 90, e.start = T, graceEndsAt = T + 1200.
        await stand.machine.tick(now: moment.addingTimeInterval(-1200))
        for offset in [-1200.0, -900.0, -700.0, -601.0] {
            await stand.machine.tick(now: moment.addingTimeInterval(offset))
            let probe0 = await stand.machine.sessions().first?.state
            XCTAssertEqual(probe0, .scheduled, "armAt не наступил")
            let probe1 = await stand.machine.prompts().isEmpty
            XCTAssertTrue(probe1, "askAt не наступил")
        }
        for offset in [-600.0, -500.0, -91.0] {
            await stand.machine.tick(now: moment.addingTimeInterval(offset))
            let probe2 = await stand.machine.sessions().first?.state
            XCTAssertEqual(probe2, .armed, "e.start не наступил")
            let probe3 = await stand.machine.prompts().isEmpty
            XCTAssertTrue(probe3, "askAt всё ещё не наступил")
        }
        for offset in [0.0, 600.0, 1199.0] {
            await stand.machine.tick(now: moment.addingTimeInterval(offset))
            let probe4 = await stand.machine.sessions().first?.state
            XCTAssertEqual(probe4,
                .awaitingSignal,
                "graceEndsAt не наступил"
            )
        }
    }

    // MARK: - К11 (инв. 14, вторая половина)

    /// Переход наступает НА ЭТОМ ЖЕ `tick`, а не на следующем; равенство `now == срок`
    /// считается наступлением; срок, пройденный во сне, исполняется первым `tick` после него.
    func test_k11_deadlinesFireOnTheVeryTickIncludingExactEquality() async throws {
        for (offset, expected) in [
            (-600.0, MeetingStatus.armed),          // armAt точно
            (0.0, MeetingStatus.awaitingSignal),    // e.start точно
            (1200.0, MeetingStatus.skipped)         // graceEndsAt точно
        ] {
            let stand = try bench()
            let event = try SessionMachineFixtures.event()
            stand.seed(event)
            await stand.machine.tick(now: moment.addingTimeInterval(-900))
            let probe5 = await stand.machine.sessions().first?.sessionId
            let identifier = try XCTUnwrap(probe5)
            await stand.machine.tick(now: moment.addingTimeInterval(offset))

            let state = await stand.machine.session(id: identifier)?.state
            XCTAssertEqual(state, expected, "равенство сроку есть наступление (смещение \(offset))")
        }
    }

    /// Срок, пройденный во сне: один `tick` через сутки исполняет всё, что прошло.
    func test_k11_deadlinesPassedWhileAsleepFireOnTheFirstTickAfterIt() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let stream = stand.machine.changes()
        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        await stand.machine.tick(now: moment.addingTimeInterval(86_400))

        let changes = await collect(stream, count: 2)
        XCTAssertEqual(
            changes.compactMap { $0.session?.state },
            [.scheduled, .skipped],
            "за верхней границей окна побеждает строка 3 — один переход, а не три"
        )
    }

    // MARK: - К12 (§4, «Переходы по сроку»)

    /// `tick` не зовётся вовсе — не наступает НИЧЕГО: ни смены состояния, ни спроса, ни
    /// вызова `setStatus`. Реализация с ленивым пересчётом при чтении краснеет только здесь.
    func test_k12_nothingHappensWithoutATick() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-900))  // одна сессия в `scheduled`
        let baseline = stand.log.signatures.count

        // Все сроки давно прошли — но `tick` не зовётся, зовутся только чтения.
        let stream = stand.machine.changes()
        _ = await stand.machine.sessions()
        _ = await stand.machine.prompts()
        let probe6 = await stand.machine.sessions().first?.sessionId
        let identifier = try XCTUnwrap(probe6)
        _ = await stand.machine.session(id: identifier)
        _ = stream

        let probe7 = await stand.machine.sessions().first?.state
        XCTAssertEqual(probe7, .scheduled, "состояние не изменилось")
        let probe8 = await stand.machine.prompts().isEmpty
        XCTAssertTrue(probe8, "спрос не поднялся")
        XCTAssertEqual(
            stand.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)"),
            0,
            "`setStatus` не зван ни разу"
        )
        XCTAssertEqual(stand.log.count(port: "JobQueue", method: "submit(_:)"), 0, "`submit` не зван")
        XCTAssertEqual(
            stand.log.count(port: "PowerPort", method: "beginActivity(reason:label:)"),
            0,
            "`beginActivity` не зван"
        )
        XCTAssertEqual(stand.log.signatures.count, baseline, "чтения наружу не ходят вовсе")
    }

    // MARK: - К13 (инв. 11; §2)

    /// `signals()` вызван РОВНО ОДИН РАЗ за жизнь машины; повторный `start(now:)` без
    /// `stop()` второй подписки не заводит. Красит это только счётчик: поведение двух сессий
    /// на фейке, отдающем всем подписчикам одно и то же, совпадает.
    func test_k13_signalsIsSubscribedExactlyOnce() async throws {
        let stand = try bench()
        let first = try SessionMachineFixtures.event()
        let second = try SessionMachineFixtures.event()
        stand.seed(first)
        stand.seed(second)

        await stand.machine.start(now: moment.addingTimeInterval(-900))
        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        let probe9 = await stand.machine.sessions().count
        XCTAssertEqual(probe9, 2, "живут две сессии одновременно")

        await stand.machine.start(now: moment.addingTimeInterval(-880))  // повторный, без `stop()`
        await stand.machine.tick(now: moment.addingTimeInterval(-880))

        XCTAssertEqual(stand.processes.signalsCallCount, 1, "подписка одна на приложение")
        await stand.machine.stop()
    }

    // MARK: - К14 (инв. 10, первая половина; §8.3)

    /// `graceEndsAt` считается от `e.start` и от момента подписки не сдвигается ни на секунду.
    /// Три значения `k` несущи: реализация с допуском «не больше минуты» зелена при 0 и 60.
    func test_k14_graceIsCountedFromTheEventNotFromTheSubscription() async throws {
        for shift in [0.0, 60.0, 600.0] {
            let stand = try bench()
            let event = try SessionMachineFixtures.event()
            stand.seed(event)

            await stand.machine.start(now: moment.addingTimeInterval(shift))
            await stand.machine.tick(now: moment.addingTimeInterval(shift))
            let probe10 = await stand.machine.sessions().first?.state
            XCTAssertEqual(probe10,
                .awaitingSignal,
                "сессия заведена строкой 1б при сдвиге \(shift)"
            )

            await stand.machine.tick(now: moment.addingTimeInterval(1199))
            let probe11 = await stand.machine.sessions().isEmpty
            XCTAssertFalse(probe11, "до `graceEndsAt` жива при сдвиге \(shift)")

            await stand.machine.tick(now: moment.addingTimeInterval(1200))
            let probe12 = await stand.machine.sessions().isEmpty
            XCTAssertTrue(probe12, "и уходит ровно в свой срок")
            await stand.machine.stop()
        }
    }

    // MARK: - К15 (инв. 10, вторая половина)

    /// Приложение запущено ПОСРЕДИ идущего созвона: сигнал с `observedAt`, предшествующим
    /// подписке, даёт звучащую цель на первом же `tick` после `start` — то есть до истечения
    /// `signalTtlSeconds` от подписки. Правила разогрева у машины нет.
    ///
    /// Полный ответ пункта — «переходит в `recording`» — часть B задачи: строки 8 в части A
    /// нет ни одной, и вектор на неё был бы красен на верной реализации.
    func test_k15_aSignalOlderThanTheSubscriptionIsFoundAtOnce() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let subscribedAt = moment.addingTimeInterval(120)
        await stand.machine.start(now: subscribedAt)
        // `observedAt` на 30 с РАНЬШЕ подписки, при `signalTtlSeconds` 60 — сигнал актуален.
        stand.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: subscribedAt.addingTimeInterval(-30)
        ))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: subscribedAt)

        let probe13 = await stand.machine.sessions().first
        let live = try XCTUnwrap(probe13)
        XCTAssertEqual(live.state, .awaitingSignal)
        XCTAssertEqual(live.target?.appKey, "us.zoom.xos", "цель найдена сразу, а не через `signalTtlSeconds`")
        await stand.machine.stop()
    }
}
