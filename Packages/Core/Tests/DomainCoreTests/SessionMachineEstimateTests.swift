//  Оценка и значения таблицы весов — К19 (поведенческая половина), К26, К28.
//  MEE-298, часть A. Пункты плана MEE-288 §3, разделы Г и Е, часть 2/8.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineEstimateTests: XCTestCase {

    private let moment = SessionMachineFixtures.start
    private let now = SessionMachineFixtures.start.addingTimeInterval(60)

    /// Строка таблицы §6 контракта. Тип, а не трёхчленный кортеж (`large_tuple`).
    private struct EstimateVector {
        let name: String
        let signals: [MeetingSignal]
        let expected: Double
    }

    /// Сессия в `awaitingSignal` внутри окна события; событие несёт провайдера `zoom`,
    /// и потому сигналы БЕЗ провайдера относятся к ней правилом 3, а с чужим — не относятся.
    private func standing(
        weights: SignalWeights,
        policy: AppSettings.RecordingPolicy = .auto
    ) async throws -> SessionMachineBench {
        let stand = SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: weights
        )
        let generated = try SessionMachineFixtures.event()
            stand.seed(generated)
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        return stand
    }

    private func clients(_ count: Int) -> [MeetingSignal] {
        (0..<count).map { index in
            SessionMachineFixtures.signal(
                kind: .clientRunning,
                weight: 0.4,
                appKey: "client.\(index)",
                observedAt: now,
                pid: Int32(700 + index)
            )
        }
    }

    private func microphone() -> MeetingSignal {
        SessionMachineFixtures.signal(
            kind: .microphoneInUse, weight: 0.4, appKey: nil, observedAt: now, pid: 800
        )
    }

    // MARK: - К26 (инв. 6, первая половина)

    /// Шесть строк таблицы §6 контракта, воспроизведённые на весах ЗАГРУЖЕННОЙ таблицы.
    /// Слияние идёт по парам «вид + источник»: каждый клиент — свой множитель.
    func test_k26_estimateReproducesTheContractsTable() async throws {
        let weights = try SessionMachineFixtures.weights()
        let vectors: [EstimateVector] = [
            EstimateVector(name: "окно события", signals: [], expected: 0.2),
            EstimateVector(name: "окно + 1 клиент", signals: clients(1), expected: 0.52),
            EstimateVector(name: "окно + 1 клиент + микрофон",
                           signals: clients(1) + [microphone()], expected: 0.712),
            EstimateVector(name: "окно + 3 клиента + микрофон",
                           signals: clients(3) + [microphone()], expected: 0.89632),
            EstimateVector(name: "окно + 5 клиентов", signals: clients(5), expected: 0.937792),
            EstimateVector(name: "окно + 6 клиентов", signals: clients(6), expected: 0.9626752)
        ]

        for vector in vectors {
            let stand = try await standing(weights: weights)
            for signal in vector.signals { stand.processes.emit(signal) }
            await stand.awaitDelivery(vector.signals.count)
            await stand.machine.tick(now: now)
            let probe0 = await stand.machine.sessions().first?.estimate ?? -1
            XCTAssertEqual(probe0, vector.expected, accuracy: 1e-9, "строка «\(vector.name)»")
            await stand.machine.stop()
        }
    }

    /// В произведение входят ТОЛЬКО отнесённые и ТОЛЬКО актуальные, и ничто иное.
    func test_k26_unrelatedAndStaleSignalsStayOutOfTheProduct() async throws {
        let weights = try SessionMachineFixtures.weights()
        let stand = try await standing(weights: weights)

        // Чужой провайдер — правило 2 не отнесло, правило 3 не применимо (provider != nil).
        stand.processes.emit(SessionMachineFixtures.signal(
            kind: .clientRunning, weight: 0.4, appKey: "alien", observedAt: now, provider: "meet", pid: 900))
        // Вышедший по сроку: возраст 61 с при `signalTtlSeconds` 60.
        stand.processes.emit(SessionMachineFixtures.signal(
            kind: .clientRunning, weight: 0.4, appKey: "stale",
            observedAt: now.addingTimeInterval(-61), pid: 901))
        await stand.awaitDelivery(2)
        await stand.machine.tick(now: now)

        let probe1 = await stand.machine.sessions().first?.estimate ?? -1
        XCTAssertEqual(probe1,
            0.2,
            accuracy: 1e-9,
            "в произведении остался один календарный сигнал"
        )
        await stand.machine.stop()
    }

    // MARK: - К19 (поведенческая половина; §5.2, последний абзац)

    /// Поведение идёт ВСЛЕД ЗА ЗНАЧЕНИЯМИ таблицы: и вес календарного сигнала, и срок
    /// актуальности. Реализация с зашитыми `0,2` и `60` краснеет здесь и нигде больше.
    func test_k19_behaviourFollowsTheLoadedTableNotLiterals() async throws {
        let shifted = try SessionMachineFixtures.weights(calendarWindow: 0.5, signalTtlSeconds: 600)
        let stand = try await standing(weights: shifted)

        let probe2 = await stand.machine.sessions().first?.estimate ?? -1
        XCTAssertEqual(probe2,
            0.5,
            accuracy: 1e-9,
            "вес календарного сигнала взят у таблицы"
        )

        // Возраст 61 с: при `signalTtlSeconds` 60 сигнал выпал бы, при 600 — актуален.
        stand.processes.emit(SessionMachineFixtures.signal(
            kind: .clientRunning, weight: 0.4, appKey: "client.0",
            observedAt: now.addingTimeInterval(-61), pid: 700))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: now)

        let probe3 = await stand.machine.sessions().first?.estimate ?? -1
        XCTAssertEqual(probe3,
            1 - 0.5 * 0.6,
            accuracy: 1e-9,
            "срок актуальности взят у таблицы, а не из литерала 60"
        )
        await stand.machine.stop()
    }

    // MARK: - К28 (инв. 7 — критерий запрещающий)

    /// Различающий вектор, названный контрактом: окно события и ПЯТЬ запущенных клиентов,
    /// ни одного `clientAudioOutput`. Оценка выше 0,9 — и сессия не переходит в `recording`
    /// ни при одной из трёх политик.
    ///
    /// В части A вход в `recording` не заводится ни одним ходом, и поведенческая половина
    /// этого пункта здесь ЗЕЛЕНА ПО ПОСТРОЕНИЮ. Различающую силу несёт текстовая половина —
    /// `SessionMachineTextTests`; названо строкой отчёта, а не спрятано.
    func test_k28_aHighEstimateStartsNoRecordingUnderAnyPolicy() async throws {
        let weights = try SessionMachineFixtures.weights()
        for policy in [AppSettings.RecordingPolicy.auto, .ask, .manual] {
            let stand = try await standing(weights: weights, policy: policy)
            for signal in clients(5) { stand.processes.emit(signal) }
            await stand.awaitDelivery(5)
            await stand.machine.tick(now: now)

            let probe4 = await stand.machine.sessions().first
            let live = try XCTUnwrap(probe4)
            XCTAssertGreaterThan(live.estimate, 0.9, "при политике \(policy)")
            XCTAssertEqual(live.estimate, 0.937792, accuracy: 1e-9)
            XCTAssertEqual(live.state, .awaitingSignal, "строки 6, 8 и 16 не сработали")
            XCTAssertNil(live.target, "и записывать нечего: `clientAudioOutput` не подавался")

            if policy == .ask {
                let probe5 = await stand.machine.prompts().first
                let prompt = try XCTUnwrap(probe5)
                try await stand.machine.answer(promptId: prompt.promptId, .record(sessionId: live.sessionId), now: now)
                await stand.machine.tick(now: now)
                let probe6 = await stand.machine.sessions().first?.state
                XCTAssertEqual(probe6,
                    .awaitingSignal,
                    "даже после ответа `.record` оценка записи не начинает"
                )
            }
            await stand.machine.stop()
        }
    }
}
