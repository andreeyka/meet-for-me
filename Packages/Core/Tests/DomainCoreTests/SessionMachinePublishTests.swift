//  Порядок публикации и поток изменений — К81, К82.
//  MEE-298, часть A. Пункты плана MEE-288 §3, раздел М, часть 6/8.
//
//  Вид (iv) К81 — сессия с `meetingId == nil` — здесь не подаётся: ad-hoc-сессий часть A не
//  заводит ни одной (строка 16 и §8.6 — часть B), и вектор был бы зелен на пустом множестве.
//  Названо строкой отчёта.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

/// Защёлка: «ход кончился» — наблюдаемое значение, а не догадка о расписании.
private actor Latch {
    private var closed = false
    func close() { closed = true }
    var isClosed: Bool { closed }
}

final class SessionMachinePublishTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench() throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К81, вид (i): `setStatus` прежде публикации

    /// Потребитель, читающий хранилище ПО СОБЫТИЮ `changes()`, читает НОВОЕ значение, а не
    /// прежнее. Порядок наблюдается последовательностью, а не конечным состоянием:
    /// реализация, публикующая снимок прежде записи, красна ровно здесь.
    func test_k81_i_setStatusHappensBeforeTheSnapshotIsPublished() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let stream = stand.machine.changes()
        let repository = stand.meetings
        let identifier = event.id
        let reader = Task { () -> MeetingStatus? in
            for await change in stream where change.session?.state == .skipped {
                guard let record = try? await repository.meeting(id: identifier) else { return nil }
                return record.status
            }
            return nil
        }

        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(-880))

        let seenByConsumer = await reader.value
        XCTAssertEqual(
            seenByConsumer,
            MeetingStatus.skipped,
            "по событию потребитель читает уже записанное значение"
        )
    }

    /// И порядок в журнале: `setStatus` встал в него ПРЕЖДЕ, чем команда вернулась.
    func test_k81_i_theCallIsInTheLogByTheTimeTheCommandReturns() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        XCTAssertEqual(stand.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)"), 0)

        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(-880))
        XCTAssertEqual(
            stand.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)"),
            1,
            "ровно один вызов на одну смену состояния"
        )
    }

    // MARK: - К81, вид (ii): команда возвращается не раньше записи

    /// Обе команды §3.1, уводящие сессию в терминальное состояние, — `skip` и `answer` с
    /// ответом `.skip`. Реализация, пишущая в хранилище «в фоне, чтобы не держать
    /// вызывающего», проходит (i) и проваливает это.
    func test_k81_ii_bothTerminalCommandsReturnOnlyAfterTheWrite() async throws {
        let byCommand = try bench()
        let first = try SessionMachineFixtures.event()
        byCommand.seed(first)
        await byCommand.machine.tick(now: moment.addingTimeInterval(-900))
        try await byCommand.machine.skip(meetingId: first.id, now: moment.addingTimeInterval(-880))
        XCTAssertEqual(
            byCommand.meetings.storedRecords.first?.status,
            .skipped,
            "на момент возврата `skip` исход уже записан"
        )

        let byAnswer = SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: .ask),
            weights: try SessionMachineFixtures.weights()
        )
        let second = try SessionMachineFixtures.event()
        byAnswer.seed(second)
        await byAnswer.machine.tick(now: moment.addingTimeInterval(-60))
        let probe0 = await byAnswer.machine.prompts().first
        let prompt = try XCTUnwrap(probe0)
        try await byAnswer.machine.answer(promptId: prompt.promptId, .skip, now: moment.addingTimeInterval(-50))
        XCTAssertEqual(
            byAnswer.meetings.storedRecords.first?.status,
            .skipped,
            "на момент возврата `answer` исход уже записан"
        )
    }

    // MARK: - К81, вид (iii): падение между переходом и записью — условие `Р`

    /// Единственный пункт плана, чей ответ есть НЕВОЗНИКНОВЕНИЕ события, и наблюдается он
    /// пределом ожидания (условие `Р` плана §2). Предел взят с положительным контролем:
    /// та же команда без задержки укладывается в него с запасом, и потому «не вернулась» —
    /// утверждение о команде, а не о расписании исполнителя.
    ///
    /// Потеря решения на этом векторе ЗАКОННА: контракт назвал границу окна точно, и пункт
    /// проверяет границу, а не отсутствие окна.
    func test_k81_iii_theCommandDoesNotReturnWhileTheWriteHasNotReturned() async throws {
        let bound: UInt64 = 300_000_000  // 0,3 с

        // Положительный контроль: без задержки команда укладывается в предел с запасом.
        let control = try bench()
        let first = try SessionMachineFixtures.event()
        control.seed(first)
        await control.machine.tick(now: moment.addingTimeInterval(-900))
        let controlLatch = Latch()
        let controlMachine = control.machine
        let controlMeeting = first.id
        let controlMoment = moment.addingTimeInterval(-880)
        let controlTask = Task {
            try? await controlMachine.skip(meetingId: controlMeeting, now: controlMoment)
            await controlLatch.close()
        }
        _ = await controlTask.value
        let probe1 = await controlLatch.isClosed
        XCTAssertTrue(probe1, "контроль: без задержки команда возвращается")

        // Вектор: `setStatus` управления не возвращает — и команда тоже.
        let stand = try bench()
        let second = try SessionMachineFixtures.event()
        stand.seed(second)
        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        stand.meetings.hang(on: .setStatus, seconds: 3600)

        let latch = Latch()
        let machine = stand.machine
        let meeting = second.id
        let when = moment.addingTimeInterval(-880)
        let hanging = Task {
            try? await machine.skip(meetingId: meeting, now: when)
            await latch.close()
        }
        try await Task.sleep(nanoseconds: bound)
        let probe2 = await latch.isClosed
        XCTAssertFalse(probe2, "команда управления не вернула: исход не записан")
        XCTAssertNotEqual(
            stand.meetings.storedRecords.first?.status,
            .skipped,
            "и решение действительно не записано — человек подтверждения не получил"
        )
        hanging.cancel()
    }

    // MARK: - К82 (инв. 21)

    /// Каждый вызов возвращает СВОЙ поток; при подписке поток отдаёт снимок, и только за ним
    /// — изменения после подписки; предыстории сверх снимка нет; всякое изменение приходит
    /// ЦЕЛИКОМ КАЖДОМУ живому потоку.
    ///
    /// Различающий вектор назван контрактом: реализация, вернувшая на два вызова один
    /// сохранённый поток, законна по сигнатуре `AsyncStream` и молча разделит изменения.
    /// Красит её только подача ДВУХ подписчиков с требованием полного набора у каждого.
    func test_k82_eachSubscriberGetsItsOwnSnapshotAndEveryChangeInFull() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let early = stand.machine.changes()                       // подписка ДО заведения
        await stand.machine.tick(now: moment.addingTimeInterval(-900))  // `scheduled`
        await stand.machine.tick(now: moment.addingTimeInterval(-300))  // `armed`

        let late = stand.machine.changes()                        // подписка ПОСЛЕ двух смен
        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(-280))

        let seenEarly = await collect(early, count: 3)
        let seenLate = await collect(late, count: 2)

        XCTAssertEqual(
            seenEarly.compactMap { $0.session?.state },
            [.scheduled, .armed, .skipped],
            "ранний подписчик видит всё, что наступило после его подписки"
        )
        XCTAssertEqual(
            seenLate.compactMap { $0.session?.state },
            [.armed, .skipped],
            "поздний — снимок на момент подписки, и только за ним изменения: предыстории нет"
        )
    }

    /// Снимок при подписке несёт ВСЕ нетерминальные сессии и ВСЕ поднятые спросы — и не
    /// несёт терминальных и снятых.
    func test_k82_theSubscriptionSnapshotCarriesSessionsAndPrompts() async throws {
        let stand = SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: .ask),
            weights: try SessionMachineFixtures.weights()
        )
        let live = try SessionMachineFixtures.event()
        let gone = try SessionMachineFixtures.event()
        stand.seed(live)
        stand.seed(gone)

        await stand.machine.tick(now: moment.addingTimeInterval(-60))   // обе + два спроса
        try await stand.machine.skip(meetingId: gone.id, now: moment.addingTimeInterval(-55))

        let stream = stand.machine.changes()
        let snapshot = await collect(stream, count: 2)
        XCTAssertEqual(snapshot.compactMap { $0.session?.meetingId }, [live.id], "только нетерминальные")
        XCTAssertEqual(snapshot.compactMap { $0.raisedPrompt }.count, 1, "и только не снятые спросы")
        XCTAssertEqual(snapshot.compactMap { $0.raisedPrompt?.sessionId }.count, 1)
    }
}
