//  Таблица переходов §7 контракта C-018 — строки до входа в запись.
//  MEE-298, часть A: К29 (стр. 1), К89 (1а), К90 (1б), К30 (2), К31 (3), К32 (4), К33 (5),
//  К35 (7), К37 (9). Пункты плана MEE-288 §3, раздел Ж, часть 3/8.
//
//  Строк 6, 8 и 10—16 здесь нет: они часть B задачи, и вектор, требующий их ответа, был бы
//  красен на верной части A. Где пункт своего ответа без них не получает, это названо
//  строкой отчёта, а не подменено ослабленным утверждением.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineTableTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    /// Вектор на одну клаузу условия §9.1. Тип, а не кортеж: трёхчленный кортеж линт
    /// считает нарушением (`large_tuple`), и MEE-289 уже платил за это прогоном.
    private struct ClauseVector {
        let name: String
        let event: MeetingEvent
        let stored: MeetingStatus
    }

    private func bench(
        policy: AppSettings.RecordingPolicy = .auto
    ) throws -> (SessionMachineBench, AppSettings) {
        let settings = SessionMachineFixtures.settings(policy: policy)
        return (SessionMachineBench(settings: settings, weights: try SessionMachineFixtures.weights()), settings)
    }

    // MARK: - К29 (строка 1: — → scheduled)

    func test_k29_row1_opensScheduledOnlyWhenEveryClauseHolds() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-900))  // now < armAt (= T − 600)

        let live = await stand.machine.sessions()
        XCTAssertEqual(live.count, 1, "положительный вектор: сессия заводится")
        XCTAssertEqual(live.first?.state, .scheduled, "строкой 1, а не 1а и не 1б")
        XCTAssertEqual(live.first?.meetingId, event.id)
        XCTAssertEqual(live.first?.origin, .scheduled)
    }

    /// Отрицательные (а), (б), (г), (д), (е) — по вектору на клаузу условия §9.1.
    func test_k29_row1_opensNothingWhenAClauseFails() async throws {
        let allDay = MeetingEventFixtures.allDayMoscow
        let cancelled = try SessionMachineFixtures.event(isCancelled: true)
        let ordinary = try SessionMachineFixtures.event()
        let vectors: [ClauseVector] = [
            ClauseVector(name: "isAllDay", event: allDay, stored: .scheduled),
            ClauseVector(name: "isCancelled", event: cancelled, stored: .scheduled),
            ClauseVector(name: "ready", event: ordinary, stored: .ready),
            ClauseVector(name: "failed", event: ordinary, stored: .failed),
            ClauseVector(name: "skipped", event: ordinary, stored: .skipped)
        ]

        for vector in vectors {
            let (stand, _) = try bench()
            stand.seed(vector.event, status: vector.stored)
            await stand.machine.tick(now: vector.event.start.addingTimeInterval(-900))
            let live = await stand.machine.sessions()
            XCTAssertTrue(live.isEmpty, "на векторе «\(vector.name)» не заводится ни одна сессия")
        }
    }

    /// Отрицательный (в): у встречи есть живая сессия — второй не появляется (инвариант 4).
    func test_k29_row1_doesNotOpenASecondSessionWhileTheFirstIsAlive() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        await stand.machine.tick(now: moment.addingTimeInterval(-800))
        await stand.machine.tick(now: moment.addingTimeInterval(-700))

        let live = await stand.machine.sessions()
        XCTAssertEqual(live.count, 1, "три `tick` подряд дают одну сессию, а не три")
    }

    /// Отрицательный (ж): `now ≥ armAt` — заводит не строка 1, а 1а либо 1б.
    func test_k29_row1_yieldsToRows1aAnd1bWhenArmAtHasPassed() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-300))  // armAt ≤ now < start

        let live = await stand.machine.sessions()
        XCTAssertEqual(live.first?.state, .armed, "строка 1а, а не 1")
    }

    /// Различающий вектор издания v3: решение человека переживает перезапуск приложения.
    /// Реализация, помнящая «была ли сессия» в памяти запуска, его проваливает.
    func test_k29_row1_humanDecisionSurvivesRestartInsideTheWindow() async throws {
        let (stand, settings) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-300))
        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(-250))

        // Перезапуск приложения: сессия его не переживает, переживает встреча своим статусом.
        let restarted = SessionMachine(
            processes: stand.processes,
            calendar: stand.calendar,
            meetings: stand.meetings,
            recordings: stand.repositories.recordings,
            transcripts: stand.repositories.transcripts,
            capture: stand.capture,
            queue: stand.queue,
            power: stand.power,
            settings: settings,
            weights: try SessionMachineFixtures.weights(),
            recordingDirectory: SessionMachineFixtures.recordingDirectory,
            captureInput: SessionMachineFixtures.captureInput,
            systemFormat: SessionMachineFixtures.systemFormat,
            micFormat: SessionMachineFixtures.micFormat
        )
        await restarted.tick(now: moment.addingTimeInterval(-200))  // всё ещё внутри окна

        let live = await restarted.sessions()
        XCTAssertTrue(live.isEmpty, "заведение читает хранимый `MeetingStatus`, а не память запуска")
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .skipped, "и решение записано")
    }

    // MARK: - К89 (строка 1а: — → armed)

    func test_k89_row1a_opensStraightIntoArmedWithoutPassingThroughScheduled() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let stream = stand.machine.changes()                     // условие `П`: подписка ДО заведения
        await stand.machine.tick(now: moment.addingTimeInterval(-600))  // now == armAt точно
        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(-500))

        let changes = await collect(stream, count: 2)
        XCTAssertEqual(changes.first?.session?.state, .armed, "первый снимок — сразу `armed`")
        XCTAssertEqual(changes.last?.session?.state, .skipped, "и второй — уже команда, а не строка 2")
    }

    /// Сроки считаются от `e.start` и от момента заведения не зависят ни на секунду.
    func test_k89_row1a_deadlinesAreCountedFromTheEventNotFromTheOpening() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-1))    // заведение в `armed`
        await stand.machine.tick(now: moment.addingTimeInterval(1200))  // now == graceEndsAt

        let snapshot = await stand.machine.sessions().first
        XCTAssertNil(snapshot, "сессия ушла в `skipped` в свой срок, а не через grace после заведения")
    }

    /// Путь подачи 2 из трёх — `CalendarChange`. Путь 3 (`start(now:)` по §10) — часть C.
    func test_k89_row1a_opensOnACalendarChangeToo() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()

        await stand.machine.start(now: moment.addingTimeInterval(-400))
        stand.calendar.emit(.upserted([event]))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: moment.addingTimeInterval(-400))

        let live = await stand.machine.sessions()
        XCTAssertEqual(live.first?.state, .armed, "событие, пришедшее потоком, заводит сессию тем же правилом")
        await stand.machine.stop()
    }

    // MARK: - К90 (строка 1б: — → awaitingSignal)

    func test_k90_row1b_opensStraightIntoAwaitingSignal() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let stream = stand.machine.changes()
        await stand.machine.tick(now: moment)  // now == e.start точно
        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(1))

        let changes = await collect(stream, count: 2)
        XCTAssertEqual(changes.first?.session?.state, .awaitingSignal, "минуя `scheduled` и `armed`")
        XCTAssertEqual(changes.last?.session?.state, .skipped)
    }

    /// При `now > graceEndsAt` не заводится ни одна сессия ни в каком состоянии.
    func test_k90_row1b_opensNothingPastGrace() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(1201))  // graceEndsAt = T + 1200

        let probe0 = await stand.machine.sessions().isEmpty
        XCTAssertTrue(probe0, "окно заведения закрыто")
        let probe1 = await stand.machine.session(id: UUID())
        XCTAssertNil(probe1, "и незнакомого `id` тоже нет")
    }

    /// Граница `now == graceEndsAt`: истинны сразу строка 1б и строка 9. Требуется исход,
    /// от порядка «заведение против сроков» НЕ зависящий (находка 7 дельты `Г`).
    func test_k90_row1b_atGraceBoundaryTheSessionEndsSkippedNoLaterThanTheNextTick() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(1200))  // now == graceEndsAt
        await stand.machine.tick(now: moment.addingTimeInterval(1200))  // следующий за заведением

        let probe2 = await stand.machine.sessions().isEmpty
        XCTAssertTrue(probe2, "сессия существовала и ушла в `skipped`")
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .skipped)
    }
}
