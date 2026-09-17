//  MEE-290: наблюдаемость двух НАЛИЧНЫХ фейков — условие `О` плана MEE-288 §2.
//
//  Условие `О` названо так: «наблюдаемость у двух наличных фейков, которой у них сегодня нет:
//  счётчик вызовов `signals()` у `FakeProcessMonitorPort` (К13) и счётчики выдач и снятий
//  токена у `FakePowerPort` (К67)». Оба пункта до этой задачи не исполнялись НИЧЕМ, и здесь
//  проверяется ровно то, чего им недоставало.
//
//  ПОЧЕМУ СЧЁТЧИКА МАЛО НЕ БЫВАЕТ, а списка — бывает. К13 красит реализацию, подписывающуюся
//  на `signals()` при заведении КАЖДОЙ сессии, и красит её ТОЛЬКО счётчиком: на фейке,
//  отдающем всем подписчикам одно и то же, поведение одной подписки и двух совпадает. К67
//  требует «взятых и отпущенных поровну», и по одному `liveActivities` двойное снятие одного
//  токена неотличимо от неснятия одного из двух — оба расклада дают один и тот же список.
//  Ровно эта неразличимость и проверяется здесь вектором: сперва показано, что старая
//  наблюдаемость на двух раскладах ОДИНАКОВА, потом — что новая их разводит.
//
//  ГРАНИЦА НАЗВАНА: ни одно утверждение этого файла не говорит об инвариантах C-008 и C-009.
//  Идемпотентность `end()` (инвариант 2 C-008) — обязанность порта; неравенство счётчиков
//  её нарушением не является и являться не может.

import XCTest
import DomainCore
import DomainTestKit

final class FakeObservabilityTests: XCTestCase {

    // MARK: - К13: счётчик вызовов `signals()` у `FakeProcessMonitorPort`

    func test_k13_processMonitorFake_countsSignalsSubscriptions() {
        let port = FakeProcessMonitorPort()
        XCTAssertEqual(port.signalsCallCount, 0, "вектор непустоты: до подписок ноль")

        let first = port.signals()
        XCTAssertEqual(port.signalsCallCount, 1, "одна подписка — один вызов")

        let second = port.signals()
        let third = port.signals()
        XCTAssertEqual(port.signalsCallCount, 3, "три подписки — три вызова")

        // Соседние счётчики не растут от подписки: счёт раздельный, а не общий.
        XCTAssertEqual(port.startObservingCallCount, 0)
        XCTAssertEqual(port.stopObservingCallCount, 0)
        _ = first
        _ = second
        _ = third
    }

    /// Вектор, ради которого счётчик и заведён: поведение одной подписки и двух на этом фейке
    /// СОВПАДАЕТ, и различает их только счёт. Без этого вектора счётчик читался бы как
    /// украшение.
    func test_k13_twoSubscriptionsAreIndistinguishableWithoutTheCounter() async {
        let port = FakeProcessMonitorPort()
        let first = port.signals()
        let second = port.signals()

        let signal = MeetingSignal(
            kind: .clientAudioOutput,
            weight: 0.8,
            pid: 4821,
            bundleId: "us.zoom.xos",
            group: ProcessGroup(appKey: "bundle:us.zoom.xos", pids: [4821], observedAt: Date(timeIntervalSince1970: 0)),
            provider: "zoom",
            meetingId: nil,
            observedAt: Date(timeIntervalSince1970: 0)
        )
        port.emit(signal)
        port.finishSignals()

        var seenByFirst: [MeetingSignal] = []
        for await value in first {
            seenByFirst.append(value)
        }
        var seenBySecond: [MeetingSignal] = []
        for await value in second {
            seenBySecond.append(value)
        }

        XCTAssertEqual(seenByFirst, [signal], "вектор непустоты: первый подписчик что-то получил")
        XCTAssertEqual(seenBySecond, seenByFirst, "по содержанию подписки неразличимы")
        XCTAssertEqual(port.signalsCallCount, 2, "а по счёту — различимы, и это вся разница")
    }

    // MARK: - К67: счётчики выдач и снятий токена у `FakePowerPort`

    func test_k67_powerFake_countsHandOutsAndReleases() async {
        let port = FakePowerPort(snapshot: snapshot())
        XCTAssertEqual(port.beginActivityCallCount, 0, "вектор непустоты: до выдач ноль")
        XCTAssertEqual(port.endActivityCallCount, 0)

        let first = await port.beginActivity(reason: .recording, label: "запись")
        let second = await port.beginActivity(reason: .processing, label: "обработка")
        XCTAssertEqual(port.beginActivityCallCount, 2)
        XCTAssertEqual(port.liveActivities.count, 2, "оба токена живы")

        first.end()
        second.end()
        XCTAssertEqual(port.endActivityCallCount, 2, "взятых и отпущенных поровну")
        XCTAssertEqual(port.liveActivities.count, 0, "остаток нулевой")
    }

    /// Два расклада, которые `liveActivities` НЕ РАЗЛИЧАЕТ: двойное снятие одного токена и
    /// неснятие одного из двух. Счётчики их разводят — это и есть «взятых и отпущенных
    /// поровну» из К67.
    func test_k67_doubleReleaseAndMissedReleaseAreTheSameToLiveActivitiesOnly() async {
        // Расклад А: два токена, один снят дважды. Живых остаётся один.
        let portA = FakePowerPort(snapshot: snapshot())
        let a1 = await portA.beginActivity(reason: .recording, label: "запись")
        _ = await portA.beginActivity(reason: .recording, label: "вторая запись")
        a1.end()
        a1.end()

        // Расклад Б: два токена, снят ровно один. Живых тоже один.
        let portB = FakePowerPort(snapshot: snapshot())
        let b1 = await portB.beginActivity(reason: .recording, label: "запись")
        _ = await portB.beginActivity(reason: .recording, label: "вторая запись")
        b1.end()

        // Прежняя наблюдаемость: расклады НЕРАЗЛИЧИМЫ.
        XCTAssertEqual(portA.liveActivities.count, 1, "вектор непустоты: живой токен есть в обоих")
        XCTAssertEqual(portA.liveActivities.count, portB.liveActivities.count, "по списку они одинаковы")

        // Новая: расклады РАЗЛИЧИМЫ, и разводит их счёт вызовов, а не счёт снятых токенов.
        XCTAssertEqual(portA.beginActivityCallCount, 2)
        XCTAssertEqual(portA.endActivityCallCount, 2, "двойное снятие видно счётом вызовов")
        XCTAssertEqual(portB.beginActivityCallCount, 2)
        XCTAssertEqual(portB.endActivityCallCount, 1, "неснятие видно недостачей")
        XCTAssertNotEqual(portA.endActivityCallCount, portB.endActivityCallCount, "расклады разведены")
    }

    /// Токен, у которого `end()` не звали вовсе, счёт снятий не двигает.
    func test_k67_untouchedTokenDoesNotMoveTheReleaseCounter() async {
        let port = FakePowerPort(snapshot: snapshot())
        _ = await port.beginActivity(reason: .processing, label: "обработка")
        XCTAssertEqual(port.beginActivityCallCount, 1, "вектор непустоты: выдача была")
        XCTAssertEqual(port.endActivityCallCount, 0, "снятий не было")
        XCTAssertEqual(port.liveActivities.count, 1)
    }

    // MARK: - Условие `Н` у питания C-008: журнал вызовов

    func test_mee290_powerFake_writesIntoSharedCallLog() async {
        let log = PortCallLog()
        let port = FakePowerPort(snapshot: snapshot(), log: log)
        XCTAssertTrue(log.isEmpty, "вектор непустоты: журнал начинается пустым")

        let token = await port.beginActivity(reason: .recording, label: "запись")
        _ = await port.snapshot()
        token.end()

        XCTAssertEqual(
            log.signatures,
            [
                "PowerPort.beginActivity(reason:label:)",
                "PowerPort.snapshot()",
                "PowerPort.PowerActivityToken.end()"
            ],
            "последовательность целиком — «прежде», а не «оба случились»"
        )
        XCTAssertTrue(
            log.happened("PowerPort.beginActivity(reason:label:)", before: "PowerPort.PowerActivityToken.end()")
        )
    }

    /// Умолчание параметра `log` ничего не ломает у прежних вызовов: фейк, собранный
    /// по-старому, заводит свой журнал и пишет в него.
    func test_mee290_powerFake_keepsWorkingWithoutAGivenLog() async {
        let port = FakePowerPort(snapshot: snapshot())
        _ = await port.snapshot()
        XCTAssertEqual(port.callLog.signatures, ["PowerPort.snapshot()"])
    }

    // MARK: - Оснастка

    private func snapshot() -> PowerSnapshot {
        PowerSnapshot(
            source: .ac,
            batteryFraction: nil,
            isLowPowerModeEnabled: false,
            thermalPressure: .nominal,
            checkedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
