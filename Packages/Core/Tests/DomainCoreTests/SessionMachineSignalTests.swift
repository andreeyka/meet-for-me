//  Собственный календарный сигнал, звучащая цель и отнесение — К16—К18, К20—К25.
//  MEE-298, часть A. Пункты плана MEE-288 §3, разделы Г и Д, часть 2/8.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineSignalTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    /// Набор §5.3 и ответ по нему. Тип, а не трёхчленный кортеж (`large_tuple`).
    private struct TargetVector {
        let name: String
        let hasTarget: Bool
        let signal: MeetingSignal
    }

    private func bench(
        weights: SignalWeights? = nil,
        policy: AppSettings.RecordingPolicy = .auto
    ) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try weights ?? SessionMachineFixtures.weights()
        )
    }

    /// Сессия в `awaitingSignal` внутри окна события, подписки поставлены.
    private func standing(
        weights: SignalWeights? = nil,
        provider: String? = "zoom"
    ) async throws -> (SessionMachineBench, MeetingEvent) {
        let stand = try bench(weights: weights)
        let event = try SessionMachineFixtures.event(provider: provider)
        stand.seed(event)
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        return (stand, event)
    }

    // MARK: - К16 (инв. 8, первая половина)

    /// Семь полей календарного сигнала — семь отдельных утверждений. Проверяются на самой
    /// функции, а не через оценку: в поток сигнал не уходит (К18), и через оценку наблюдаемы
    /// лишь `weight` и факт существования, а `pid`, `bundleId` и `provider` — ничем.
    func test_k16_calendarSignalCarriesAllSevenFields() throws {
        let weights = try SessionMachineFixtures.weights(calendarWindow: 0.35)
        let event = try SessionMachineFixtures.event()
        let now = moment.addingTimeInterval(60)

        let signal = try XCTUnwrap(SessionMachineRules.calendarSignal(
            for: event, origin: .scheduled, weights: weights, now: now
        ))

        XCTAssertEqual(signal.kind, .calendarWindow)
        XCTAssertNil(signal.pid)
        XCTAssertNil(signal.bundleId)
        XCTAssertNil(signal.group)
        XCTAssertNil(signal.provider)
        XCTAssertEqual(signal.meetingId, event.id)
        XCTAssertEqual(signal.observedAt, now)
        XCTAssertEqual(signal.weight, 0.35, "вес берётся у ЗАГРУЖЕННОЙ таблицы, а не из литерала")
    }

    // MARK: - К17 (инв. 8, вторая половина)

    /// Сигнал существует ТОГДА И ТОЛЬКО ТОГДА, когда `e.start ≤ now < e.end`. Границы
    /// несимметричны, и вектор подаёт обе точно: в `e.start` — есть, в `e.end` — нет.
    func test_k17_calendarSignalExistsExactlyInsideTheHalfOpenWindow() throws {
        let weights = try SessionMachineFixtures.weights()
        let event = try SessionMachineFixtures.event()  // окно [T, T + 1800)

        for (offset, exists) in [
            (-1.0, false), (0.0, true), (900.0, true), (1799.0, true), (1800.0, false), (1801.0, false)
        ] {
            let signal = SessionMachineRules.calendarSignal(
                for: event, origin: .scheduled, weights: weights, now: moment.addingTimeInterval(offset)
            )
            XCTAssertEqual(signal != nil, exists, "на смещении \(offset) от начала события")
        }
    }

    /// И то же поведением: внутри окна оценка несёт вес календарного сигнала, вне — ноль.
    /// Окно события здесь короче grace намеренно — иначе сессия уходит в `skipped` раньше,
    /// чем кончается окно, и наблюдать нечего.
    func test_k17_theWindowIsObservableThroughTheEstimate() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event(duration: 600)  // окно [T, T + 600)
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let probe0 = await stand.machine.sessions().first?.estimate ?? -1
        XCTAssertEqual(probe0, 0.2, accuracy: 1e-9)

        await stand.machine.tick(now: moment.addingTimeInterval(600))  // ровно `e.end`
        let probe1 = await stand.machine.sessions().first?.estimate ?? -1
        XCTAssertEqual(probe1, 0, accuracy: 1e-9)
        let probe2 = await stand.machine.sessions().first?.state
        XCTAssertEqual(probe2, .awaitingSignal, "сессия ещё жива")
    }

    // MARK: - К18 (инв. 9, проверяемая половина)

    /// Два `tick` с разрывом `d < signalTtlSeconds` дают два сигнала с разрывом ровно `d`;
    /// в поток `signals()` календарный сигнал не уходит и вторым потребителем не наблюдается.
    func test_k18_calendarSignalsAreRebuiltEachTickAndNeverPublished() async throws {
        let weights = try SessionMachineFixtures.weights()
        let event = try SessionMachineFixtures.event()
        let first = SessionMachineRules.calendarSignal(
            for: event, origin: .scheduled, weights: weights, now: moment.addingTimeInterval(60)
        )
        let second = SessionMachineRules.calendarSignal(
            for: event, origin: .scheduled, weights: weights, now: moment.addingTimeInterval(90)
        )
        let gap = try XCTUnwrap(second?.observedAt.timeIntervalSince(try XCTUnwrap(first?.observedAt)))
        XCTAssertEqual(gap, 30, accuracy: 1e-9, "разрыв равен разрыву `tick` и меньше `signalTtlSeconds`")

        // Второй потребитель потока порта: сторожевой сигнал приходит к нему ПЕРВЫМ — значит
        // за три `tick` внутри окна машина не опубликовала в поток ни одного своего.
        let (stand, _) = try await standing()
        let observer = stand.processes.signals()
        await stand.machine.tick(now: moment.addingTimeInterval(90))
        await stand.machine.tick(now: moment.addingTimeInterval(120))
        await stand.machine.tick(now: moment.addingTimeInterval(150))
        let sentinel = SessionMachineFixtures.signal(
            kind: .clientRunning, weight: 0.4, appKey: "sentinel", observedAt: moment.addingTimeInterval(150)
        )
        stand.processes.emit(sentinel)

        var seen: [MeetingSignal] = []
        for await value in observer {
            seen.append(value)
            break
        }
        XCTAssertEqual(seen.first, sentinel, "первым в поток пришёл сторожевой, а не календарный")
        await stand.machine.stop()
    }

    // MARK: - К20 (§5.3, определение)

    /// Звучащая цель есть ТОЛЬКО у актуального `clientAudioOutput` с группой.
    func test_k20_onlyAnActualClientAudioOutputWithAGroupIsASoundingTarget() async throws {
        let now = moment.addingTimeInterval(60)
        let vectors: [TargetVector] = [
            TargetVector(name: "clientRunning", hasTarget: false, signal: SessionMachineFixtures.signal(
                kind: .clientRunning, weight: 0.4, appKey: "us.zoom.xos", observedAt: now)),
            TargetVector(name: "microphoneInUse", hasTarget: false, signal: SessionMachineFixtures.signal(
                kind: .microphoneInUse, weight: 0.4, appKey: nil, observedAt: now)),
            TargetVector(name: "вышедший по сроку", hasTarget: false,
                         signal: SessionMachineFixtures.audioOutput(
                             appKey: "us.zoom.xos", observedAt: now.addingTimeInterval(-61))),
            TargetVector(name: "актуальный clientAudioOutput", hasTarget: true,
                         signal: SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: now))
        ]

        for vector in vectors {
            let (stand, _) = try await standing()
            stand.processes.emit(vector.signal)
            await stand.awaitDelivery(1)
            await stand.machine.tick(now: now)
            let target = await stand.machine.sessions().first?.target
            XCTAssertEqual(target != nil, vector.hasTarget, "набор «\(vector.name)»")
            await stand.machine.stop()
        }

        // (д) собственный календарный сигнал целью не является — он уже в наборе всегда.
        let (calendarOnly, _) = try await standing()
        let probe3 = await calendarOnly.machine.sessions().first?.target
        XCTAssertNil(probe3, "набор «calendarWindow»")
        await calendarOnly.machine.stop()
    }

    // MARK: - К21 (инв. 12, первая половина; §5.3, три ступени)

    func test_k21_targetIsChosenByProviderThenByObservedAtThenByAppKey() async throws {
        let now = moment.addingTimeInterval(60)

        // Ступень 1: провайдер события сильнее прочих, даже при меньшем `observedAt`.
        let (byProvider, _) = try await standing()
        // «Прочий» обязан относиться к сессии, иначе ступень 1 не с чем сравнивать: сигнал
        // ЧУЖОГО провайдера правило 2 к ней не относит вовсе, и до §5.3 он не доходит.
        byProvider.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "com.other.app", observedAt: now, provider: nil))
        byProvider.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now.addingTimeInterval(-10), provider: "zoom", pid: 502))
        await byProvider.awaitDelivery(2)
        await byProvider.machine.tick(now: now)
        let probe4 = await byProvider.machine.sessions().first?.target?.appKey
        XCTAssertEqual(probe4, "us.zoom.xos", "ступень 1")
        await byProvider.machine.stop()

        // Ступень 2: провайдер не различает — побеждает больший `observedAt`.
        let (byMoment, _) = try await standing(provider: nil)
        byMoment.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "aaa.app", observedAt: now.addingTimeInterval(-20), provider: nil))
        byMoment.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "zzz.app", observedAt: now, provider: nil, pid: 502))
        await byMoment.awaitDelivery(2)
        await byMoment.machine.tick(now: now)
        let probe5 = await byMoment.machine.sessions().first?.target?.appKey
        XCTAssertEqual(probe5, "zzz.app", "ступень 2")
        await byMoment.machine.stop()

        // Ступень 3: `observedAt` равны — побеждает лексикографически меньший `appKey`.
        // Набор подаётся в порядке, ОБРАТНОМ ответу, и повторно: «первый в массиве» краснеет.
        let (byKey, _) = try await standing(provider: nil)
        byKey.processes.emit(SessionMachineFixtures.audioOutput(appKey: "zzz.app", observedAt: now, provider: nil))
        byKey.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "aaa.app", observedAt: now, provider: nil, pid: 502))
        await byKey.awaitDelivery(2)
        for _ in 0..<3 {
            await byKey.machine.tick(now: now)
            let probe6 = await byKey.machine.sessions().first?.target?.appKey
            XCTAssertEqual(probe6, "aaa.app", "ступень 3")
        }
        await byKey.machine.stop()
    }

    // MARK: - К22 (инв. 12, вторая половина)

    /// `clientAudioOutput` с `group == nil` целью не является; машина на нём не падает и
    /// продолжает выбирать цель среди годных сигналов того же набора.
    func test_k22_aSignalWithoutAGroupIsNotATargetAndBreaksNothing() async throws {
        let now = moment.addingTimeInterval(60)
        let (stand, _) = try await standing()
        stand.processes.emit(SessionMachineFixtures.signal(
            kind: .clientAudioOutput, weight: 0.8, appKey: nil, observedAt: now, provider: "zoom"))
        stand.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now, pid: 502))
        await stand.awaitDelivery(2)
        await stand.machine.tick(now: now)

        let probe7 = await stand.machine.sessions().first
        let live = try XCTUnwrap(probe7)
        XCTAssertEqual(live.state, .awaitingSignal, "негодный вход машину не уронил")
        XCTAssertEqual(live.target?.appKey, "us.zoom.xos", "цель выбрана среди годных")
        await stand.machine.stop()
    }

    // MARK: - К23 (§5.4, правила 1—4)

    /// Правило 1: календарный сигнал относится к сессии со своим `meetingId` и ни к какой
    /// другой. Читаются правила в порядке 1—4, и порядок этот существен.
    func test_k23_rule1_calendarSignalBelongsToItsOwnSessionOnly() throws {
        let mine = try SessionMachineFixtures.event()
        let other = try SessionMachineFixtures.event()
        let weights = try SessionMachineFixtures.weights()
        let now = moment.addingTimeInterval(60)
        let signal = try XCTUnwrap(SessionMachineRules.calendarSignal(
            for: mine, origin: .scheduled, weights: weights, now: now))
        let deadlines = SessionMachineRules.arm(for: other, settings: SessionMachineFixtures.settings())

        XCTAssertTrue(SessionMachineRules.relates(
            signal: signal,
            to: SessionMachineRules.SessionSide(
                meetingId: mine.id, state: .awaitingSignal, provider: "zoom", deadlines: deadlines
            ),
            now: now))
        XCTAssertFalse(SessionMachineRules.relates(
            signal: signal,
            to: SessionMachineRules.SessionSide(
                meetingId: other.id, state: .awaitingSignal, provider: "zoom", deadlines: deadlines
            ),
            now: now),
            "чужая сессия с открытым окном его не получает — правило 1 стоит первым")
    }

    /// Правила 2, 3 и 4 и оконная оговорка обеими половинами.
    func test_k23_rules2to4_windowAndProviderAreBothRead() throws {
        let event = try SessionMachineFixtures.event()
        let settings = SessionMachineFixtures.settings()
        let deadlines = SessionMachineRules.arm(for: event, settings: settings)
        let inside = moment.addingTimeInterval(60)
        let outside = moment.addingTimeInterval(1201)   // за `graceEndsAt`

        let zoom = SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: inside, provider: "zoom")
        let meet = SessionMachineFixtures.audioOutput(appKey: "com.google", observedAt: inside, provider: "meet")
        let plain = SessionMachineFixtures.audioOutput(appKey: "browser", observedAt: inside, provider: nil)

        // Правило 2: провайдер совпал и окно открыто.
        XCTAssertTrue(SessionMachineRules.relates(
            signal: zoom,
            to: SessionMachineRules.SessionSide(
                meetingId: event.id, state: .awaitingSignal, provider: "zoom", deadlines: deadlines
            ),
            now: inside))
        // ...и вторая половина оговорки: вне окна, но в `recording`/`stopping`.
        XCTAssertTrue(SessionMachineRules.relates(
            signal: zoom,
            to: SessionMachineRules.SessionSide(
                meetingId: event.id, state: .recording, provider: "zoom", deadlines: deadlines
            ),
            now: outside))
        // Правило 4: провайдер не совпал ни с одним.
        XCTAssertFalse(SessionMachineRules.relates(
            signal: meet,
            to: SessionMachineRules.SessionSide(
                meetingId: event.id, state: .awaitingSignal, provider: "zoom", deadlines: deadlines
            ),
            now: inside))
        // Правило 3: провайдера нет — решает окно.
        XCTAssertTrue(SessionMachineRules.relates(
            signal: plain,
            to: SessionMachineRules.SessionSide(
                meetingId: event.id, state: .awaitingSignal, provider: "zoom", deadlines: deadlines
            ),
            now: inside))
        XCTAssertFalse(SessionMachineRules.relates(
            signal: plain,
            to: SessionMachineRules.SessionSide(
                meetingId: event.id, state: .awaitingSignal, provider: "zoom", deadlines: deadlines
            ),
            now: outside),
            "окно закрыто — сигнал не относится и оценки не поднимает")
    }
}
