//  Ad-hoc после перезапуска, оценка и место правила `1а` — К97, К26 (вид ii), К23.
//  MEE-307, часть C. Пункты плана MEE-288 §3, разделы Ж и З.
//
//  У ТРЁХ ПУНКТОВ ЗДЕСЬ НЕ БЫЛО НИ ОДНОГО ВЕКТОРА ДО ЭТОЙ ЗАДАЧИ. К97 не было чем подать:
//  ветвь (а) требует, чтобы цель пришла СНИМКОМ ПРИ ПОДПИСКЕ после `start(now:)`, а снимка
//  фейк не отдавал (условие `Ю`). К26 (ii) до издания v6 был зелен на нуле, и вектор,
//  требующий у ad-hoc-сессии нулевой оценки, сегодня красит ВЕРНУЮ машину.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineAdHocRestartTests: XCTestCase {

    private let moment = SessionMachineFixtures.start
    private let appKey = "us.zoom.xos"

    private func bench(policy: AppSettings.RecordingPolicy) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    private func target(at observedAt: Date, appKey: String? = nil) -> MeetingSignal {
        SessionMachineFixtures.audioOutput(appKey: appKey ?? self.appKey, observedAt: observedAt)
    }

    // MARK: - К97 (§10, перечень А; инвариант 4, последнее предложение)

    /// Ветвь (а): ad-hoc-сессия в `awaitingSignal`, спрос не отвечен, строки `recordings` у
    /// неё НЕТ НИ ОДНОЙ. `stop()`, затем `start(now:)`; цель по-прежнему актуальна и
    /// приходит СНИМКОМ ПРИ ПОДПИСКЕ.
    ///
    /// `start(now:)` не восстанавливает этой сессии ничем — перечень А поднимает только
    /// записи, а записи у неё нет; перечень Б её не видит вовсе, потому что `meetingId` у
    /// неё `nil`. НО СЕССИЯ ЗАВОДИТСЯ ЗАНОВО СТРОКОЙ 1в по тому же сигналу, и спрос
    /// поднимается заново. Обе половины Ответа проверяются: реализация, пытающаяся
    /// восстановить такую сессию, нарушает инвариант 4; реализация, НЕ заводящая её заново
    /// по живой цели, проваливает вторую половину.
    func test_k97_a_anAdHocSessionIsNotRestoredButOpenedAnewByItsLiveTarget() async throws {
        let stand = try bench(policy: .auto)
        await stand.machine.start(now: moment)
        await stand.deliver(target(at: moment))
        await stand.machine.tick(now: moment)
        let before = try unwrap(await stand.machine.sessions().first)
        await stand.machine.stop()

        let restarted = try bench(policy: .auto)
        restarted.processes.setSnapshot([target(at: moment.addingTimeInterval(10))])
        await restarted.machine.start(now: moment.addingTimeInterval(10))

        XCTAssertEqual(
            restarted.log.count(port: "RecordingRepository", method: "unfinalized()"), 1,
            "перечень А прочитан — и записи у этой сессии нет ни одной"
        )
        let probe1 = await restarted.machine.sessions()
        XCTAssertTrue(
            probe1.isEmpty,
            "перечнями А и Б не восстановлено ничего: тождества в хранилище у неё нет"
        )

        await restarted.awaitDelivery(1)
        await restarted.machine.tick(now: moment.addingTimeInterval(10))
        let after = try unwrap(await restarted.machine.sessions().first)
        XCTAssertEqual(after.origin, .adHoc, "но заведена ЗАНОВО строкой 1в по живой цели")
        XCTAssertNotEqual(after.sessionId, before.sessionId, "`sessionId` НОВЫЙ; К7 не нарушен")
        let probe2 = await restarted.machine.prompts()
        XCTAssertEqual(probe2.count, 1, "и спрос поднят заново")
        await restarted.machine.stop()
    }

    /// Отрицательный к (а): цель к моменту `start(now:)` перестала быть актуальной — сессия
    /// не заводится ни одна и спрос не поднимается ни один.
    func test_k97_a_negative_aDeadTargetOpensNothingAfterRestart() async throws {
        let weights = try SessionMachineFixtures.weights()
        let stand = try bench(policy: .auto)
        stand.processes.setSnapshot([target(at: moment)])
        let late = moment.addingTimeInterval(TimeInterval(weights.signalTtlSeconds) + 1)

        await stand.machine.start(now: late)
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: late)

        let probe3 = await stand.machine.sessions()
        XCTAssertTrue(probe3.isEmpty, "сессии не заводится ни одной")
        let probe4 = await stand.machine.prompts()
        XCTAssertTrue(probe4.isEmpty, "и спроса ни одного")
        await stand.machine.stop()
    }

    /// Ветвь (б): ad-hoc-сессия, дошедшая до `recording`, — строка `recordings` есть,
    /// `RecordingStatus` равен `.recording`, `manifest.meetingId == nil`. Она
    /// восстанавливается ПЕРЕЧНЕМ А по записи: `recover`, приведение к `.finalized`, вход в
    /// `processing`; `origin` определяется участием записи в ответе `adHoc()` (издание v8,
    /// К77), а не значением `manifest.meetingId` — у этой записи оно `nil` с момента
    /// создания (она изначально ad-hoc), и потому она отдаётся `adHoc()` и получает
    /// `origin == .adHoc` тем же основанием, каким прежде (издание v7) читалось само поле:
    /// ответ этого пункта не меняется, меняется только контрактная опора, на которую он
    /// ссылается.
    func test_k97_b_anAdHocRecordingIsRestoredByListA() async throws {
        let stand = try bench(policy: .auto)
        let recordingId = UUID()
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: nil)
        stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .recording)])
        stand.capture.setRecoverManifest(manifest)

        await stand.machine.start(now: moment)

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.origin, .adHoc, "отдана `adHoc()` (нет привязки к встрече) → `.adHoc`")
        XCTAssertNil(live.meetingId)
        XCTAssertEqual(live.state, .processing, "восстановлена перечнем А по записи")
        XCTAssertEqual(live.recordingId, recordingId)
        await stand.machine.stop()
    }

    // MARK: - К26, вид (ii) (инв. 6, первая половина)

    /// `estimate` ad-hoc-сессии НЕ НУЛЕВОЙ ни в одном её нетерминальном состоянии: в
    /// произведение входит её цель, отнесённая правилом `1а`, и всякий иной сигнал,
    /// отнесённый к ней тем же правилом; КАЛЕНДАРНОГО МНОЖИТЕЛЯ у неё нет ни одного.
    ///
    /// ВЕКТОР КРАСИТ ВЧЕРАШНЮЮ ВЕРНУЮ РЕАЛИЗАЦИЮ: до издания v6 к ad-hoc-сессии не
    /// относился ни один сигнал, и ноль был верным ответом.
    func test_k26_ii_theAdHocEstimateIsNotZeroInAnyLiveState() async throws {
        let weights = try SessionMachineFixtures.weights()
        let stand = try bench(policy: .auto)
        await stand.machine.start(now: moment)
        await stand.deliver(target(at: moment))
        await stand.machine.tick(now: moment)

        let waiting = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(
            waiting.estimate, 1 - (1 - weights.weight(for: .clientAudioOutput)), accuracy: 1e-9,
            "в `awaitingSignal`: множитель ровно один — её цель правилом `1а`"
        )

        let promptId = try unwrap(await stand.machine.prompts().first?.promptId)
        stand.allowCaptureStart()
        try await stand.machine.answer(promptId: promptId, .record(sessionId: waiting.sessionId),
                                       now: moment.addingTimeInterval(1))
        let recording = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(recording.state, .recording, "оснастка: сессия пишет")
        XCTAssertGreaterThan(recording.estimate, 0, "в `recording` оценка тоже не нулевая")
        await stand.machine.stop()
    }

    // MARK: - К23, правило `1а` и его место

    /// Правило `1а` стоит РАНЬШЕ правил 2 и 3 — и это несущее. Отрицательные к нему два:
    /// (а) терминальная ad-hoc-сессия — правило не срабатывает; (б) другой `appKey` — тоже.
    func test_k23_rule1aComesBeforeRules2And3AndHasItsTwoNegatives() throws {
        let signal = target(at: moment)
        let adHoc = SessionMachineRules.SessionSide(
            meetingId: nil, origin: .adHoc, state: .awaitingSignal,
            provider: nil, deadlines: nil, adHocAppKey: appKey
        )
        XCTAssertEqual(
            SessionMachineRules.relation(signal: signal, to: adHoc, now: moment), .rule1aAdHoc,
            "правило `1а` относит сигнал к ad-hoc-сессии"
        )

        let terminal = SessionMachineRules.SessionSide(
            meetingId: nil, origin: .adHoc, state: .skipped,
            provider: nil, deadlines: nil, adHocAppKey: appKey
        )
        XCTAssertNil(
            SessionMachineRules.relation(signal: signal, to: terminal, now: moment),
            "(а) терминальная ad-hoc-сессия: правило `1а` не срабатывает"
        )

        let other = SessionMachineRules.SessionSide(
            meetingId: nil, origin: .adHoc, state: .awaitingSignal,
            provider: nil, deadlines: nil, adHocAppKey: "com.microsoft.teams"
        )
        XCTAssertNil(
            SessionMachineRules.relation(signal: signal, to: other, now: moment),
            "(б) другой `appKey`: правило `1а` не срабатывает"
        )
    }

    /// Отнесение правилом `1а` СТОРОНОЙ СПОРА не делает, а отнесение правилами 2 и 3 —
    /// делает. Это и есть то место издания v7, ради которого ответом служит номер правила,
    /// а не «да/нет».
    func test_k23_onlyRules2And3MakeADisputeParty() {
        XCTAssertFalse(SessionMachineRules.Relation.rule1Calendar.isDisputeParty)
        XCTAssertFalse(SessionMachineRules.Relation.rule1aAdHoc.isDisputeParty, "`1а` — не сторона")
        XCTAssertTrue(SessionMachineRules.Relation.rule2Provider.isDisputeParty)
        XCTAssertTrue(SessionMachineRules.Relation.rule3NoProvider.isDisputeParty)
    }
}
