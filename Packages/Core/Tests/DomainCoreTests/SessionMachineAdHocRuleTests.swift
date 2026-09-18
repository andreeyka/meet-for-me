//  Правило `1а` §5.4 и ad-hoc-сессия — К95, К96, К97, К26 (вид ii), К23 (правило `1а`).
//  MEE-307, часть C. Пункты плана MEE-288 §3, разделы Ж и З.
//
//  ДО ЭТОЙ ЗАДАЧИ У ЧЕТЫРЁХ ИЗ ПЯТИ ПУНКТОВ НЕ БЫЛО НИ ОДНОГО ВЕКТОРА, и у К95, К96 и К97
//  не было их ПО ПОСТРОЕНИЮ: субъекта не существовало, пока §5.4 не относил к ad-hoc-сессии
//  ни одного сигнала. Правило `1а` заведено изданием v6, и вместе с ним стали подаваемы и
//  оценка ad-hoc-сессии (К26 вид ii), и её единственность по НАЗНАЧЕННОМУ `appKey` (К96,
//  издание v7).
//
//  УСЛОВИЕ `Ю`. Второй путь подачи К95 — «снимок при подписке» — до этой задачи не
//  существовал: фейк отдавал подписчику только то, что опубликовано ПОСЛЕ подписки, и
//  сигнал, поданный до неё, не был виден никому. `setSnapshot(_:)` заведён ради него.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineAdHocRuleTests: XCTestCase {

    private let moment = SessionMachineFixtures.start
    private let appKey = "us.zoom.xos"

    /// Стенд без единого события календаря: всякая цель здесь не отнесена ни к одной сессии
    /// правилами 2 и 3 — то есть ровно вход §8.6.
    private func bench(policy: AppSettings.RecordingPolicy) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    private func target(at observedAt: Date, appKey: String? = nil) -> MeetingSignal {
        SessionMachineFixtures.audioOutput(appKey: appKey ?? self.appKey, observedAt: observedAt)
    }

    // MARK: - К95 (строка 1в: — → `awaitingSignal`, ad-hoc)

    /// Путь подачи первый — `tick(now:)` по опубликованным сигналам. Сессия заводится СРАЗУ
    /// в `awaitingSignal`, минуя все прочие состояния, с заполненным и АКТУАЛЬНЫМ `target`:
    /// целью назначен этот самый сигнал (правило `1а`). Снимков ровно один, `setStatus` не
    /// зван ни разу.
    func test_k95_row1vOpensStraightIntoAwaitingSignalWithItsTargetFilled() async throws {
        for policy in [AppSettings.RecordingPolicy.auto, .ask] {
            let stand = try bench(policy: policy)
            let stream = stand.machine.changes()
            await stand.machine.start(now: moment)
            await stand.deliver(target(at: moment))
            await stand.machine.tick(now: moment)

            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.state, .awaitingSignal, "\(policy): сразу в `awaitingSignal`")
            XCTAssertEqual(live.origin, .adHoc)
            XCTAssertNil(live.meetingId, "К1: `meetingId == nil`")
            XCTAssertNil(live.recordingId, "К3: `recordingId == nil` до входа в запись")
            XCTAssertEqual(live.target?.appKey, appKey, "`target` заполнен правилом `1а`")

            let published = await collect(stream, count: 2)
            XCTAssertEqual(
                published.compactMap { $0.session?.state }, [.awaitingSignal],
                "\(policy): снимков ровно один, и переходов строками 1, 1а, 1б, 2 и 7 нет"
            )
            XCTAssertEqual(published.compactMap(\.raisedPrompt).count, 1, "и спрос ровно один")
            XCTAssertEqual(
                stand.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)"), 0,
                "\(policy): `setStatus` не зван ни разу — `meetingId` у неё `nil`"
            )
            await stand.machine.stop()
        }
    }

    /// Путь подачи второй, и он обязателен: СНИМОК ПРИ ПОДПИСКЕ после `start(now:)` —
    /// приложение запущено посреди идущего незапланированного созвона (К15, К13).
    /// Сигнал опубликован ДО подписки и не проходит через `emit`.
    func test_k95_theSubscriptionSnapshotOpensTheAdHocSessionToo() async throws {
        let stand = try bench(policy: .auto)
        stand.processes.setSnapshot([target(at: moment)])

        await stand.machine.start(now: moment)
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: moment)

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.origin, .adHoc, "машина поднялась над УЖЕ идущим созвоном")
        XCTAssertEqual(live.state, .awaitingSignal)
        XCTAssertEqual(live.target?.appKey, appKey)
        await stand.machine.stop()
    }

    /// Отрицательный (а): `.manual` — строка 1в не срабатывает, сессии нет и спроса нет.
    func test_k95_a_manualOpensNothingByRow1v() async throws {
        let stand = try bench(policy: .manual)
        await stand.machine.start(now: moment)
        await stand.deliver(target(at: moment))
        await stand.machine.tick(now: moment)

        let probe1 = await stand.machine.sessions()
        XCTAssertTrue(probe1.isEmpty, "сессии не заводится ни одной")
        let probe2 = await stand.machine.prompts()
        XCTAssertTrue(probe2.isEmpty, "и спрос не поднимается ни один")
        await stand.machine.stop()
    }

    /// Отрицательный (б′) — ЗАВЕДЁН ИЗДАНИЕМ v7 И РАЗЛИЧАЮЩИЙ. При `.auto` и `.ask`, на том
    /// же сигнале и при истинном условии заведения, подана команда
    /// `startRecording(meetingId: nil)` ДО первого `tick`: строка 1в НЕ срабатывает, сессию
    /// заводит СТРОКА 16 сразу в `recording`, и спроса не поднимается ни одного.
    ///
    /// Реализация, отдавшая победу строке 1в по порядку таблицы, отвечает спросом на прямое
    /// указание человека и проваливает вектор: моменты чтения у двух строк РАЗНЫЕ, и
    /// порядок таблицы между ними не решает.
    func test_k95_bPrime_aCommandBeforeTheFirstTickBeatsRow1v() async throws {
        for policy in [AppSettings.RecordingPolicy.auto, .ask] {
            let stand = try bench(policy: policy)
            stand.allowCaptureStart()
            let stream = stand.machine.changes()
            await stand.machine.start(now: moment)
            await stand.deliver(target(at: moment))

            let recordingId = try await stand.machine.startRecording(meetingId: nil, now: moment)

            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.state, .recording, "\(policy): сразу в `recording` строкой 16")
            XCTAssertEqual(live.recordingId, recordingId)
            XCTAssertEqual(live.origin, .adHoc)
            let probe3 = await stand.machine.prompts()
            XCTAssertTrue(
                probe3.isEmpty,
                "\(policy): спроса не поднимается ни одного даже при `.auto` и `.ask`"
            )
            // РОВНО ОДИН элемент, а не «первые два»: их и опубликовано ровно столько.
            // Снимок `awaitingSignal` строка 16 не публикует — сессия в этом состоянии не
            // стояла ни одного хода, — и `promptRaised` не публикует тоже (К44).
            let published = await collect(stream, count: 1)
            XCTAssertEqual(
                published.compactMap { $0.session?.state }, [.recording],
                "\(policy): снимков ровно один, и его `state` равен `recording`"
            )
            XCTAssertEqual(
                published.compactMap(\.raisedPrompt).count, 0, "\(policy): `promptRaised` ноль"
            )
            await stand.machine.tick(now: moment.addingTimeInterval(1))
            let all = await stand.machine.sessions()
            XCTAssertEqual(all.count, 1, "\(policy): второй сессии не заводится ни одной")
            await stand.machine.stop()
        }
    }

    /// Отрицательный (г): сигнал не актуален по инварианту 25 C-009 — не заводится.
    /// Отрицательный (д): `group == nil` — не заводится (инвариант 12).
    func test_k95_staleSignalsAndGrouplessSignalsOpenNothing() async throws {
        let weights = try SessionMachineFixtures.weights()
        let stale = try bench(policy: .auto)
        await stale.machine.start(now: moment)
        await stale.deliver(target(at: moment))
        let past = moment.addingTimeInterval(TimeInterval(weights.signalTtlSeconds) + 1)
        await stale.machine.tick(now: past)
        let probe4 = await stale.machine.sessions()
        XCTAssertTrue(probe4.isEmpty, "сигнал не актуален — не заводится")
        await stale.machine.stop()

        let groupless = try bench(policy: .auto)
        await groupless.machine.start(now: moment)
        await groupless.deliver(MeetingSignal(
            kind: .clientAudioOutput, weight: 0.8, pid: 501, bundleId: appKey,
            group: nil, provider: "zoom", meetingId: nil, observedAt: moment
        ))
        await groupless.machine.tick(now: moment)
        let probe5 = await groupless.machine.sessions()
        XCTAssertTrue(probe5.isEmpty, "`group == nil` — не заводится")
        await groupless.machine.stop()
    }

    // MARK: - К96 (инвариант 4, третья половина; признак переписан изданием v7)

    /// Тот же сигнал подаётся ПОВТОРНО, `tick` за `tick`, не менее трёх раз подряд, и
    /// подаётся актуальным в каждый из моментов. ПРОВЕРЯЕТСЯ СЧЁТОМ ЗА ПРОГОН: число
    /// заведённых ad-hoc-сессий равно единице, число `promptRaised` — единице.
    ///
    /// РАЗЛИЧАЮЩИЙ ВЕКТОР ЛОВИТ ПОВЕДЕНИЕ, КОТОРОЕ ДО ИЗДАНИЯ v6 БЫЛО ЗАКОННЫМ: реализация,
    /// у которой §5.4 не относит сигнал к уже заведённой ad-hoc-сессии, заводит по нему
    /// новую сессию с новым спросом КАЖДЫМ `tick`, без предела, — и проходит всякий пункт,
    /// спрашивающий об одном `tick`.
    func test_k96_theSameTargetOpensExactlyOneAdHocSessionOverTheWholeRun() async throws {
        let stand = try bench(policy: .auto)
        let stream = stand.machine.changes()
        await stand.machine.start(now: moment)

        for step in 0..<4 {
            let at = moment.addingTimeInterval(Double(step) * 10)
            await stand.deliver(target(at: at))
            await stand.machine.tick(now: at)
        }

        let sessions = await stand.machine.sessions()
        XCTAssertEqual(sessions.count, 1, "за прогон заведена РОВНО ОДНА ad-hoc-сессия")
        let probe6 = await stand.machine.prompts()
        XCTAssertEqual(probe6.count, 1, "и ровно один спрос")
        let published = await collect(stream, count: 2)
        XCTAssertEqual(
            published.compactMap(\.raisedPrompt).count, 1, "событий `promptRaised` ровно одно"
        )
        await stand.machine.stop()
    }

    /// Отрицательный (а): повторный сигнал несёт ДРУГОЙ `appKey` — вторая ad-hoc-сессия
    /// заводится, и это верный исход, а не нарушение.
    func test_k96_a_aDifferentAppKeyOpensASecondAdHocSession() async throws {
        let stand = try bench(policy: .auto)
        await stand.machine.start(now: moment)
        await stand.deliver(target(at: moment))
        await stand.machine.tick(now: moment)
        await stand.deliver(target(at: moment.addingTimeInterval(5), appKey: "com.microsoft.teams"))
        await stand.machine.tick(now: moment.addingTimeInterval(5))

        let sessions = await stand.machine.sessions()
        XCTAssertEqual(sessions.count, 2, "другая цель — вторая сессия, и это верно")
        XCTAssertEqual(
            Set(sessions.compactMap { $0.target?.appKey }), [appKey, "com.microsoft.teams"]
        )
        await stand.machine.stop()
    }

    /// Отрицательный (б): первая сессия стала ТЕРМИНАЛЬНОЙ — заведение по тому же `appKey`
    /// разрешено, сессия заводится и спрос поднимается заново (К97).
    func test_k96_b_aTerminalAdHocSessionFreesItsAppKey() async throws {
        let stand = try bench(policy: .auto)
        await stand.machine.start(now: moment)
        await stand.deliver(target(at: moment))
        await stand.machine.tick(now: moment)
        let first = try unwrap(await stand.machine.sessions().first)
        let promptId = try unwrap(await stand.machine.prompts().first?.promptId)

        try await stand.machine.answer(promptId: promptId, .skip, now: moment.addingTimeInterval(1))
        let probe7 = await stand.machine.sessions()
        XCTAssertTrue(probe7.isEmpty, "оснастка: первая терминальна")

        await stand.deliver(target(at: moment.addingTimeInterval(2)))
        await stand.machine.tick(now: moment.addingTimeInterval(2))
        let second = try unwrap(await stand.machine.sessions().first)
        XCTAssertNotEqual(second.sessionId, first.sessionId, "заведена НОВАЯ сессия")
        XCTAssertEqual(second.target?.appKey, appKey, "по тому же `appKey`, и это разрешено")
        await stand.machine.stop()
    }

    /// Отрицательный (в) — ЗАВЕДЁН ИЗДАНИЕМ v7 И РАЗЛИЧАЮЩИЙ. Цель живой ad-hoc-сессии
    /// ПЕРЕСТАЛА БЫТЬ АКТУАЛЬНОЙ, пока сессия жива в `recording` (срок §8.4 не истёк,
    /// `SessionSnapshot.target` равен `nil`), и ТОТ ЖЕ сигнал опубликован снова — второй
    /// сессии не заводится ни одной.
    ///
    /// Реализация, читающая `target`, а не хранящая НАЗНАЧЕННЫЙ `appKey`, этот вектор
    /// проваливает: `nil` не равен `appKey` ни одному, и условие заведения §8.6 у неё
    /// становится истинным.
    func test_k96_c_anExtinguishedTargetStillHoldsTheAssignedAppKey() async throws {
        let stand = try bench(policy: .manual)
        stand.allowCaptureStart()
        let weights = try SessionMachineFixtures.weights()
        await stand.machine.start(now: moment)
        await stand.deliver(target(at: moment))
        _ = try await stand.machine.startRecording(meetingId: nil, now: moment)

        // Цель гаснет: сигнал старше `signalTtlSeconds`, а срок §8.4 ещё не истёк.
        let dark = moment.addingTimeInterval(TimeInterval(weights.signalTtlSeconds) + 1)
        await stand.machine.tick(now: dark)
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "оснастка: запись жива")
        XCTAssertNil(live.target, "оснастка: `target` погас")

        await stand.deliver(target(at: dark))
        await stand.machine.tick(now: dark)
        let sessions = await stand.machine.sessions()
        XCTAssertEqual(sessions.count, 1, "второй сессии не заводится ни одной")
        XCTAssertEqual(sessions.first?.sessionId, live.sessionId, "она же самая")
        await stand.machine.stop()
    }
}
