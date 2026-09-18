//  Восстановление §10, перечень Б по встречам — К78, К79, К80, К91.
//  MEE-307, часть C. Пункты плана MEE-288 §3, разделы И и Л, часть 5/8.
//
//  ПОРЯДОК ПЕРЕЧНЕЙ — ЧАСТЬ ОТВЕТА, А НЕ ОСНАСТКА: К78 требует, чтобы записи читались
//  прежде встреч, и наблюдается это журналом вызовов, а не конечным состоянием.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineRestoreTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К78 (§10, перечень Б; инв. 22, половина по `MeetingStatus`; инв. 24)

    /// Девять значений — девять названных ответов, пропусков нет; у части встреч есть
    /// незавершённая запись, у части нет ни одной.
    func test_k78_everyMeetingStatusHasItsNamedAnswer() async throws {
        let openable: Set<MeetingStatus> = [.scheduled, .armed, .awaitingSignal]
        let byRecording: Set<MeetingStatus> = [.recording, .stopping, .processing]
        for status in [MeetingStatus.scheduled, .armed, .awaitingSignal, .recording, .stopping,
                       .processing, .ready, .failed, .skipped] {
            let stand = try bench()
            let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(600))
            stand.seed(event, status: status)

            await stand.machine.start(now: moment)
            let sessions = await stand.machine.sessions()

            if openable.contains(status) {
                XCTAssertEqual(sessions.count, 1, "\(status): сессия заводится заново по §9.1")
                XCTAssertEqual(sessions.first?.meetingId, event.id)
            } else if byRecording.contains(status) {
                XCTAssertTrue(sessions.isEmpty, "\(status): записей ноль — сессии ни одной")
                XCTAssertEqual(
                    stand.meetings.storedRecords.first?.status, .failed,
                    "\(status): статус ложен — машина ставит `failed`"
                )
            } else {
                XCTAssertTrue(sessions.isEmpty, "\(status): терминальный — сессия не заводится")
            }
            await stand.machine.stop()
        }
    }

    /// «ЗАПИСЕЙ НОЛЬ» — ИЗДАНИЕ v7, И ВЕКТОР ПОДАЁТСЯ ОТДЕЛЬНО ОТ ПЕРЕБОРА ДЕВЯТИ ЗНАЧЕНИЙ,
    /// потому что «записей ноль» не есть значение `RecordingStatus` и декартовым перебором
    /// двух перечислений не покрывается ничем. Наблюдается двумя ответами разом:
    /// `setStatus(.failed)` вызван — И `sessions()` новой сессии не отдаёт, а `changes()` по
    /// этой встрече не публикует ни одного снимка.
    func test_k78_zeroRecordingsGiveFailedToTheMeetingAndNoSessionAtAll() async throws {
        for status in [MeetingStatus.recording, .stopping, .processing] {
            let stand = try bench()
            let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(600))
            stand.seed(event, status: status)
            let stream = stand.machine.changes()

            await stand.machine.start(now: moment)

            XCTAssertEqual(
                stand.meetings.storedRecords.first?.status, .failed,
                "\(status): `setStatus(.failed)` вызван"
            )
            let sessions = await stand.machine.sessions()
            XCTAssertTrue(sessions.isEmpty, "\(status): сессии не заводится НИ ОДНОЙ")

            // «Ни одного снимка» наблюдается ПЕРВЫМ элементом потока, а не пустотой:
            // ждать пустоты у бесконечного потока нечем. После `start` подаётся заведомый
            // ad-hoc-вход, и если снимок этой встречи был опубликован, первым придёт он.
            await stand.deliver(SessionMachineFixtures.audioOutput(
                appKey: "us.zoom.xos", observedAt: moment
            ))
            await stand.machine.tick(now: moment)
            let published = await collect(stream, count: 1)
            XCTAssertEqual(
                published.first?.session?.origin, .adHoc,
                "\(status): первым снимком идёт ad-hoc-вход, то есть по встрече не было ни одного"
            )
            await stand.machine.stop()
        }
    }

    /// Терминальные три: отказ обязан наблюдаться И НА ПЕРВОМ `tick` после `start(now:)`,
    /// а не только в момент `start`, — это следствие §9.1, а не второе правило.
    func test_k78_theTerminalThreeRefuseOnTheFirstTickToo() async throws {
        for status in [MeetingStatus.ready, .failed, .skipped] {
            let stand = try bench()
            let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(600))
            stand.seed(event, status: status)

            await stand.machine.start(now: moment)
            await stand.machine.tick(now: moment)
            await stand.machine.tick(now: moment.addingTimeInterval(60))

            let sessions = await stand.machine.sessions()
            XCTAssertTrue(sessions.isEmpty, "\(status): и на первом `tick` тоже")
            await stand.machine.stop()
        }
    }

    /// Порядок чтения значим и проверяется: СПЕРВА ЗАПИСИ (перечень А), ПОТОМ ВСТРЕЧИ.
    func test_k78_recordsAreReadBeforeMeetings() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(600))
        stand.seed(event, status: .scheduled)
        let manifest = try SessionMachineFixtures.manifest(recordingId: UUID(), meetingId: nil)
        stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .failed)])

        await stand.machine.start(now: moment)

        XCTAssertTrue(
            stand.log.happened("RecordingRepository.unfinalized()", before: "MeetingRepository.meetings(from:to:)"),
            "сперва записи, потом встречи"
        )
        await stand.machine.stop()
    }

    // MARK: - К79 (§10, «два перечня не спорят по построению»)

    /// Пара, в которой перечни расходятся: встреча в `MeetingStatus.ready` при записи в
    /// `RecordingStatus.recording`. Исход берётся из А: сессия входит в `processing`, а
    /// `setStatus` приводит встречу к фактическому состоянию — и ПРЕЖДЕ публикации снимка.
    func test_k79_theTwoListsDisagreeAndListAWins() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(600))
        stand.seed(event, status: .ready)
        let recordingId = UUID()
        let manifest = try SessionMachineFixtures.manifest(
            recordingId: recordingId, meetingId: event.id
        )
        stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .recording)])
        stand.capture.setRecoverManifest(manifest)

        await stand.machine.start(now: moment)

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .processing, "исход взят из перечня А")
        XCTAssertEqual(live.meetingId, event.id, "и это сессия ЭТОЙ встречи")
        XCTAssertEqual(
            stand.meetings.storedRecords.first?.status, .processing,
            "`setStatus` привёл встречу к фактическому состоянию"
        )
        XCTAssertTrue(
            stand.log.happened("MeetingRepository.setStatus(_:meetingId:)", before: "JobQueue.submit(_:)"),
            "инвариант 18: запись прежде дальнейшего хода"
        )
        await stand.machine.stop()
    }

    // MARK: - К80 (§10; §8.2, «ответ на спрос не хранится»)

    /// Ветвь (а): спрос поднят и не отвечен, `stop()`, затем `start(now:)`. Сессия заводится
    /// заново по §9.1, поднятый до перезапуска спрос НЕ ВОССТАНАВЛИВАЕТСЯ, и спрос
    /// поднимается ЗАНОВО — в момент заведения, если `askAt` уже прошёл.
    func test_k80_a_anUnansweredPromptIsNotRestoredButRaisedAnew() async throws {
        let first = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(60))
        first.seed(event, status: .awaitingSignal)
        await first.machine.start(now: moment)
        await first.machine.tick(now: moment)
        let before = await first.machine.prompts()
        await first.machine.stop()

        let second = try bench(policy: .ask)
        second.seed(event, status: .awaitingSignal)
        await second.machine.start(now: moment.addingTimeInterval(120))

        let after = await second.machine.prompts()
        XCTAssertEqual(before.count, 1, "оснастка: спрос до перезапуска был")
        XCTAssertEqual(after.count, 1, "и поднялся заново")
        XCTAssertNotEqual(after.first?.promptId, before.first?.promptId, "спрос НОВЫЙ, а не тот же")
        XCTAssertEqual(
            after.first?.raisedAt, moment.addingTimeInterval(120),
            "`raisedAt` равен моменту заведения, а не `askAt` (К93)"
        )
        let live = try unwrap(await second.machine.sessions().first)
        XCTAssertNotEqual(live.sessionId, before.first?.sessionId, "`sessionId` новый; К7 не нарушен")
        await second.machine.stop()
    }

    /// Ветвь (б): спрос отвечен `.skip`, встреча стоит в `skipped` — сессия НЕ ЗАВОДИТСЯ
    /// ВОВСЕ и спрос не поднимается: заведение читает терминальный `MeetingStatus`.
    func test_k80_b_aSkippedMeetingOpensNoSessionAndRaisesNoPrompt() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(60))
        stand.seed(event, status: .skipped)

        await stand.machine.start(now: moment)
        await stand.machine.tick(now: moment)

        XCTAssertTrue(await stand.machine.sessions().isEmpty, "сессии не заводится вовсе")
        XCTAssertTrue(await stand.machine.prompts().isEmpty, "и спрос не поднимается")
        await stand.machine.stop()
    }

    /// Ветвь (в): спрос отвечен `.record`, встреча стоит в `recording` — судьбу определяет
    /// запись по перечню А, и спрос не поднимается.
    func test_k80_c_aRecordingMeetingIsDecidedByItsRecordAndRaisesNoPrompt() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(60))
        stand.seed(event, status: .recording)
        let manifest = try SessionMachineFixtures.manifest(recordingId: UUID(), meetingId: event.id)
        stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .recording)])
        stand.capture.setRecoverManifest(manifest)

        await stand.machine.start(now: moment)

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .processing, "судьбу определила запись (перечень А)")
        XCTAssertTrue(await stand.machine.prompts().isEmpty, "спрос не поднимается")
        await stand.machine.stop()
    }

    // MARK: - К91 (инвариант 24; §9.1, первый пункт; §10, перечень Б)

    /// Различающий вектор, названный самим контрактом: команда `skip` → `stop()` →
    /// `start(now:)` ВНУТРИ окна до `graceEndsAt` → `tick`. Реализация, помнящая «была ли у
    /// встречи сессия» в ПАМЯТИ ЗАПУСКА, проходит `tick` и `CalendarChange` и проваливает
    /// эти два входа.
    func test_k91_theSkipDecisionSurvivesARestartInsideTheWindow() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(60))
        stand.seed(event)
        await stand.machine.start(now: moment)
        await stand.machine.tick(now: moment)
        try await stand.machine.skip(meetingId: event.id, now: moment)
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .skipped, "оснастка: решение записано")
        await stand.machine.stop()

        let restarted = try bench()
        restarted.repositories.meetings.seed(stand.meetings.storedRecords)
        let settings = SessionMachineFixtures.settings()
        let arm = SessionMachineRules.arm(for: event, settings: settings)
        let inside = arm.graceEndsAt.addingTimeInterval(-60)
        XCTAssertLessThan(inside, arm.graceEndsAt, "оснастка: перезапуск ВНУТРИ окна")

        await restarted.machine.start(now: inside)
        await restarted.machine.tick(now: inside)

        XCTAssertTrue(
            await restarted.machine.sessions().isEmpty,
            "решение человека не отменяется сроком: правило одно на все запуски"
        )
        await restarted.machine.stop()
    }

    /// Входы (а) и (б): сколько угодно `tick` подряд и `CalendarChange` на то же событие —
    /// на трёх терминальных значениях сессия не заводится ни строкой 1, ни 1а, ни 1б.
    func test_k91_neitherRepeatedTicksNorCalendarChangesOpenATerminalMeeting() async throws {
        for status in [MeetingStatus.ready, .failed, .skipped] {
            let stand = try bench()
            let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(60))
            stand.seed(event, status: status)
            await stand.machine.start(now: moment)
            for step in 0..<4 {
                await stand.machine.tick(now: moment.addingTimeInterval(Double(step) * 30))
            }
            let moved = try SessionMachineFixtures.event(
                id: event.id, start: moment.addingTimeInterval(1200)
            )
            await stand.deliver(CalendarChange.upserted([moved]))
            await stand.machine.tick(now: moment.addingTimeInterval(180))

            XCTAssertTrue(
                await stand.machine.sessions().isEmpty,
                "\(status): ни один из входов сессии не заводит"
            )
            await stand.machine.stop()
        }
    }
}
