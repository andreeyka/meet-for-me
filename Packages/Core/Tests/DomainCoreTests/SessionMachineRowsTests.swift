//  Таблица переходов §7 — строки 2, 3, 4, 5, 7 и 9. Продолжение
//  `SessionMachineTableTests`: К30, К31, К32, К33, К35, К37.
//  MEE-298, часть A. Пункты плана MEE-288 §3, раздел Ж, часть 3/8.
//
//  Файл отделён от первого по одному доводу и он механический: `--strict` линта считает
//  файл длиннее четырёхсот строк нарушением. Предмет не делится — делится текст.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineRowsTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(
        policy: AppSettings.RecordingPolicy = .auto
    ) throws -> (SessionMachineBench, AppSettings) {
        let settings = SessionMachineFixtures.settings(policy: policy)
        return (SessionMachineBench(settings: settings, weights: try SessionMachineFixtures.weights()), settings)
    }

    // MARK: - К30 (строка 2: scheduled → armed)

    func test_k30_row2_firesOnTheClosedIntervalAndNowhereElse() async throws {
        for (offset, expected) in [
            (-601.0, MeetingStatus.scheduled),   // раньше armAt
            (-600.0, MeetingStatus.armed),       // armAt точно
            (-300.0, MeetingStatus.armed),       // внутри
            (1200.0, MeetingStatus.skipped),     // graceEndsAt точно: 2 → 7 → 9 за один `tick`
            (1201.0, MeetingStatus.skipped)      // за верхней границей: строка 3
        ] {
            let (stand, _) = try bench()
            let generated = try SessionMachineFixtures.event()
            stand.seed(generated)

            await stand.machine.tick(now: moment.addingTimeInterval(-900))  // завели в `scheduled`
            await stand.machine.tick(now: moment.addingTimeInterval(offset))

            XCTAssertEqual(
                stand.meetings.storedRecords.first?.status,
                expected,
                "на смещении \(offset) ожидается \(expected)"
            )
        }
    }

    /// При `now > graceEndsAt` строка 2 не срабатывает вовсе — и это единственное место,
    /// где краснеет редакция без верхней границы.
    func test_k30_row2_doesNotFirePastGraceSoRow3Wins() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let stream = stand.machine.changes()
        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        await stand.machine.tick(now: moment.addingTimeInterval(1500))

        let changes = await collect(stream, count: 2)
        XCTAssertEqual(changes.first?.session?.state, .scheduled)
        XCTAssertEqual(changes.last?.session?.state, .skipped, "за один `tick`, а не за три")
    }

    // MARK: - К31 (строка 3: scheduled → skipped)

    func test_k31_row3_firesOnEachOfItsThreeClauses() async throws {
        // Клауза «команда `skip`».
        let (byCommand, _) = try bench()
        let first = try SessionMachineFixtures.event()
        byCommand.seed(first)
        await byCommand.machine.tick(now: moment.addingTimeInterval(-900))
        try await byCommand.machine.skip(meetingId: first.id, now: moment.addingTimeInterval(-880))
        XCTAssertEqual(byCommand.meetings.storedRecords.first?.status, .skipped)

        // Клауза «событие удалено».
        let (byDeletion, _) = try bench()
        let second = try SessionMachineFixtures.event()
        byDeletion.seed(second)
        await byDeletion.machine.start(now: moment.addingTimeInterval(-900))
        await byDeletion.machine.tick(now: moment.addingTimeInterval(-900))
        byDeletion.calendar.emit(.deleted([second.id]))
        await byDeletion.awaitDelivery(1)
        await byDeletion.machine.tick(now: moment.addingTimeInterval(-880))
        XCTAssertEqual(byDeletion.meetings.storedRecords.first?.status, .skipped)
        await byDeletion.machine.stop()

        // Клауза `now > graceEndsAt`.
        let (byDeadline, _) = try bench()
        let third = try SessionMachineFixtures.event()
        byDeadline.seed(third)
        await byDeadline.machine.tick(now: moment.addingTimeInterval(-900))
        await byDeadline.machine.tick(now: moment.addingTimeInterval(1201))
        XCTAssertEqual(byDeadline.meetings.storedRecords.first?.status, .skipped)
    }

    /// Знак строгий: при `now == graceEndsAt` из `scheduled` побеждает строка 2, а не 3.
    /// Асимметрия со строкой 9 (`≥`) намеренна, и «выравнивать» её запрещено.
    func test_k31_row3_isStrictWhileRow9IsNot() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let stream = stand.machine.changes()
        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        await stand.machine.tick(now: moment.addingTimeInterval(1200))  // ровно graceEndsAt

        let changes = await collect(stream, count: 4)
        XCTAssertEqual(
            changes.compactMap { $0.session?.state },
            [.scheduled, .armed, .awaitingSignal, .skipped],
            "в сам момент `graceEndsAt` строка 2 срабатывает, а уводит в `skipped` строка 9"
        )
    }

    // MARK: - К32 (строка 4: armed → skipped)

    func test_k32_row4_firesOnCommandOnAnswerAndOnDeletion() async throws {
        // Команда `skip`.
        let (byCommand, _) = try bench()
        let first = try SessionMachineFixtures.event()
        byCommand.seed(first)
        await byCommand.machine.tick(now: moment.addingTimeInterval(-300))
        try await byCommand.machine.skip(meetingId: first.id, now: moment.addingTimeInterval(-280))
        XCTAssertEqual(byCommand.meetings.storedRecords.first?.status, .skipped)

        // Ответ `.skip` на поднятый спрос.
        let (byAnswer, _) = try bench(policy: .ask)
        let second = try SessionMachineFixtures.event()
        byAnswer.seed(second)
        await byAnswer.machine.tick(now: moment.addingTimeInterval(-60))  // askAt = T − 90 пройден
        let probe0 = await byAnswer.machine.prompts().first
        let prompt = try XCTUnwrap(probe0)
        try await byAnswer.machine.answer(promptId: prompt.promptId, .skip, now: moment.addingTimeInterval(-50))
        XCTAssertEqual(byAnswer.meetings.storedRecords.first?.status, .skipped)

        // Событие удалено.
        let (byDeletion, _) = try bench()
        let third = try SessionMachineFixtures.event()
        byDeletion.seed(third)
        await byDeletion.machine.start(now: moment.addingTimeInterval(-300))
        await byDeletion.machine.tick(now: moment.addingTimeInterval(-300))
        byDeletion.calendar.emit(.deleted([third.id]))
        await byDeletion.awaitDelivery(1)
        await byDeletion.machine.tick(now: moment.addingTimeInterval(-290))
        XCTAssertEqual(byDeletion.meetings.storedRecords.first?.status, .skipped)
        await byDeletion.machine.stop()
    }

    /// `now ≥ graceEndsAt` условием строки 4 не является: раньше срабатывает строка 7.
    func test_k32_row4_hasNoGraceClauseBecauseRow7ComesFirst() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let stream = stand.machine.changes()
        await stand.machine.tick(now: moment.addingTimeInterval(-300))  // `armed`
        await stand.machine.tick(now: moment.addingTimeInterval(1200))

        let changes = await collect(stream, count: 3)
        XCTAssertEqual(
            changes.compactMap { $0.session?.state },
            [.armed, .awaitingSignal, .skipped],
            "из `armed` по сроку grace идут через строку 7, а не строкой 4"
        )
    }

    // MARK: - К33 (строка 5: armed → scheduled)

    func test_k33_row5_returnsToScheduledOnlyWhenTheNewArmAtIsStillAhead() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.start(now: moment.addingTimeInterval(-300))
        await stand.machine.tick(now: moment.addingTimeInterval(-300))
        let probe1 = await stand.machine.sessions().first
        let opened = try XCTUnwrap(probe1)
        XCTAssertEqual(opened.state, .armed)

        // Сдвиг вперёд на час: новый armAt = T + 3600 − 600, то есть впереди.
        let shifted = try SessionMachineFixtures.event(id: event.id, start: moment.addingTimeInterval(3600))
        stand.calendar.emit(.upserted([shifted]))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: moment.addingTimeInterval(-290))

        let probe2 = await stand.machine.sessions().first
        let back = try XCTUnwrap(probe2)
        XCTAssertEqual(back.state, .scheduled, "сессия вернулась в `scheduled` и взводится по новому окну")
        XCTAssertEqual(back.sessionId, opened.sessionId, "и не пересоздана (К7)")
        await stand.machine.stop()
    }

    func test_k33_row5_doesNotReturnWhenTheNewArmAtHasAlreadyPassed() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.start(now: moment.addingTimeInterval(-300))
        await stand.machine.tick(now: moment.addingTimeInterval(-300))

        // Сдвиг вперёд на 120 с: новый armAt = T + 120 − 600 = T − 480, уже прошёл.
        let shifted = try SessionMachineFixtures.event(id: event.id, start: moment.addingTimeInterval(120))
        stand.calendar.emit(.upserted([shifted]))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: moment.addingTimeInterval(-290))

        let probe3 = await stand.machine.sessions().first?.state
        XCTAssertEqual(probe3, .armed, "остаётся взведённой")
        await stand.machine.stop()
    }

    // MARK: - К35 (строка 7: armed → awaitingSignal)

    func test_k35_row7_firesAtEventStartAndNotBefore() async throws {
        for (offset, expected) in [(-1.0, MeetingStatus.armed), (0.0, .awaitingSignal), (60.0, .awaitingSignal)] {
            let (stand, _) = try bench()
            let event = try SessionMachineFixtures.event()
            stand.seed(event)

            await stand.machine.tick(now: moment.addingTimeInterval(-300))
            await stand.machine.tick(now: moment.addingTimeInterval(offset))

            let probe4 = await stand.machine.sessions().first?.state
            XCTAssertEqual(probe4,
                expected,
                "на смещении \(offset) от начала события"
            )
        }
    }

    // MARK: - К37 (строка 9: awaitingSignal → skipped)

    func test_k37_row9_firesOnEachClauseAndAtTheGraceMomentItself() async throws {
        // Клауза «команда `skip`».
        let (byCommand, _) = try bench()
        let first = try SessionMachineFixtures.event()
        byCommand.seed(first)
        await byCommand.machine.tick(now: moment.addingTimeInterval(60))
        let probe5 = await byCommand.machine.sessions().first?.state
        XCTAssertEqual(probe5, .awaitingSignal)
        try await byCommand.machine.skip(meetingId: first.id, now: moment.addingTimeInterval(70))
        XCTAssertEqual(byCommand.meetings.storedRecords.first?.status, .skipped)

        // Клауза «ответ `.skip`».
        let (byAnswer, _) = try bench(policy: .ask)
        let second = try SessionMachineFixtures.event()
        byAnswer.seed(second)
        await byAnswer.machine.tick(now: moment.addingTimeInterval(60))
        let probe6 = await byAnswer.machine.prompts().first
        let prompt = try XCTUnwrap(probe6)
        try await byAnswer.machine.answer(promptId: prompt.promptId, .skip, now: moment.addingTimeInterval(70))
        XCTAssertEqual(byAnswer.meetings.storedRecords.first?.status, .skipped)

        // Клауза «`now ≥ graceEndsAt` и звучащей цели нет» — в САМ момент `graceEndsAt`.
        let (byDeadline, _) = try bench()
        let third = try SessionMachineFixtures.event()
        byDeadline.seed(third)
        await byDeadline.machine.tick(now: moment.addingTimeInterval(60))
        await byDeadline.machine.tick(now: moment.addingTimeInterval(1200))
        XCTAssertEqual(byDeadline.meetings.storedRecords.first?.status, .skipped, "знак `≥`, а не `>`")
    }
}
