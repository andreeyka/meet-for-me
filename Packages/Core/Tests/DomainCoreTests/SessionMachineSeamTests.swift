//  ПЕРЕПРОВЕРКА ШВА A/B — шестнадцать пунктов, закрытых частью A не полностью.
//  MEE-300, часть B, §4 постановки.
//
//  Десять пунктов — `К1, К3, К5, К6, К7, К28, К45, К46, К81, К86` — были в части A зелены
//  ПО ПОСТРОЕНИЮ: их утверждения истинны потому, что противного пути не существовало, а не
//  потому, что реализация его закрыла. Шесть — `К15, К35, К37, К49, К51, К52` — закрыты
//  различающей половиной, а полный ответ называл `recording`, которого не было.
//
//  Здесь поданы ровно те половины, которых не было: состояния записи и обработки теперь
//  существуют, и утверждение каждого пункта проверяется на них, а не на их отсутствии.
//  Файл отдельный намеренно: приёмка части B обязана пройти по шестнадцати поимённо, и
//  собранные в одном месте они читаются, а рассыпанные по девяти файлам — нет.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineSeamTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    /// Проход до `ready` целиком: `awaitingSignal` → `recording` → `stopping` →
    /// `processing` → `ready`. Оснастка вынесена в `SessionMachineWholeWay`, чтобы два
    /// файла перепроверки не держали двух её редакций.
    private func wholeWay() async throws -> SessionMachineWholeWay {
        try await SessionMachineWholeWay.build(from: moment)
    }

    // MARK: - К1 (инв. 4, первая половина; §1.1, §1.3)

    /// `meetingId == nil` тогда и только тогда, когда `origin == .adHoc`, — В КАЖДОМ
    /// ДОСТИЖИМОМ состоянии, а не в пяти из девяти. Часть A проверить этого не могла:
    /// `recording`, `stopping` и `processing` она не заводила ни одним входом.
    func test_k1_meetingIdFollowsOriginInEveryReachableStateIncludingRecording() async throws {
        let way = try await wholeWay()
        let terminal = try unwrap(await way.stand.machine.session(id: way.sessionId))
        XCTAssertEqual(terminal.state, .ready, "оснастка: путь пройден целиком")
        XCTAssertEqual(terminal.origin, .scheduled)
        XCTAssertEqual(terminal.meetingId, way.event.id, "у `.scheduled` `meetingId` есть везде")
        await way.stand.machine.stop()

        // Обратная половина «тогда и только тогда»: ad-hoc несёт `nil` в `recording` и
        // дальше — подставлять его нечем ни на одном ходу.
        let adHoc = try bench(policy: .manual)
        adHoc.allowCaptureStart()
        adHoc.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        await adHoc.machine.start(now: moment)
        await adHoc.deliver(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: moment))
        await adHoc.machine.tick(now: moment)
        let recordingId = try await adHoc.machine.startRecording(meetingId: nil, now: moment)
        let recording = try unwrap(await adHoc.machine.sessions().first)
        XCTAssertEqual(recording.origin, .adHoc)
        XCTAssertNil(recording.meetingId, "в `recording` — `nil`")

        try await adHoc.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(10))
        await adHoc.deliver(CaptureEvent.failed(.notRunning))
        await adHoc.machine.tick(now: moment.addingTimeInterval(20))
        let terminalAdHoc = try unwrap(await adHoc.machine.session(id: recording.sessionId))
        XCTAssertEqual(terminalAdHoc.state, .failed)
        XCTAssertNil(terminalAdHoc.meetingId, "и в терминальном состоянии — `nil`")
        await adHoc.machine.stop()
    }

    // MARK: - К3 (инв. 5; §1.3)

    /// `recordingId` равен `nil` во всех состояниях ДО `recording`; при входе назначается;
    /// от этого момента и до терминального ВКЛЮЧИТЕЛЬНО не меняется ни одним входом.
    func test_k3_theRecordingIdIsAssignedOnceAndSurvivesToTheTerminalState() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let before = try unwrap(await stand.machine.sessions().first)
        XCTAssertNil(before.recordingId, "до `recording` — `nil`")

        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let recording = try unwrap(await stand.machine.sessions().first)
        let assigned = try XCTUnwrap(recording.recordingId)

        try await stand.machine.stopRecording(recordingId: assigned, now: moment.addingTimeInterval(70))
        let stopping = try unwrap(await stand.machine.session(id: recording.sessionId))
        XCTAssertEqual(stopping.recordingId, assigned, "в `stopping` не изменился")

        await stand.deliver(CaptureEvent.failed(.systemUnavailable(message: "отказ")))
        await stand.machine.tick(now: moment.addingTimeInterval(80))
        let terminal = try unwrap(await stand.machine.session(id: recording.sessionId))
        XCTAssertEqual(terminal.state, .failed)
        XCTAssertEqual(terminal.recordingId, assigned, "и в терминальном состоянии — тот же")
        await stand.machine.stop()
    }

    // MARK: - К5 и К6 (инв. 3)

    /// Терминальная сессия не меняется НИ ОДНИМ входом — включая те, которых в части A не
    /// было вовсе: события захвата и очереди. И команда к ней бросает `sessionIsTerminal`,
    /// а не `noSuchSession` и не молчаливый успех.
    func test_k5_k6_aTerminalSessionIgnoresCaptureAndJobEventsAndRejectsEveryCommand() async throws {
        let way = try await wholeWay()
        let stand = way.stand
        let terminal = try unwrap(await stand.machine.session(id: way.sessionId))
        XCTAssertEqual(terminal.state, .ready, "оснастка: сессия терминальна")

        await stand.deliver(CaptureEvent.failed(.notRunning))
        await stand.deliver(JobEvent.cancelled(jobId: UUID(), type: .attribute))
        await stand.deliver(PowerEvent.didWake)
        await stand.machine.tick(now: moment.addingTimeInterval(2000))
        let after = try unwrap(await stand.machine.session(id: way.sessionId))
        XCTAssertEqual(after.state, .ready, "состояние не изменилось ни на одном входе")

        await assertTerminal(stand, state: .ready) {
            _ = try await stand.machine.startRecording(meetingId: way.event.id, now: self.moment)
        }
        await assertTerminal(stand, state: .ready) {
            try await stand.machine.stopRecording(recordingId: way.recordingId, now: self.moment)
        }
        await assertTerminal(stand, state: .ready) {
            try await stand.machine.skip(meetingId: way.event.id, now: self.moment)
        }
        await stand.machine.stop()
    }

    // MARK: - К7 (§1.3)

    /// `sessionId` назначается при заведении и не меняется НИ ОДНИМ переходом — теперь по
    /// всему пути до `ready`, а не по его первой половине.
    func test_k7_theSessionIdSurvivesTheWholeWayToReady() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        let stream = stand.machine.changes()
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let recordingId = try unwrap(await stand.machine.sessions().first?.recordingId)
        try await stand.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(70))
        await stand.deliver(CaptureEvent.failed(.notRunning))
        await stand.machine.tick(now: moment.addingTimeInterval(80))

        let changes = await collect(stream, count: 4)
        let identifiers = Set(changes.compactMap { $0.session?.sessionId })
        XCTAssertEqual(identifiers.count, 1, "сессия одна и та же на всём пути")
        let states = changes.compactMap { $0.session?.state }
        XCTAssertEqual(states, [.awaitingSignal, .recording, .stopping, .failed])
        await stand.machine.stop()
    }

    // MARK: - К28 (инв. 7 — критерий запрещающий)

    /// Высокая оценка записи не начинает НИ ПРИ ОДНОЙ политике — и теперь это утверждение
    /// проверяется на машине, которая записывать УМЕЕТ. В части A оно было истинно потому,
    /// что входа в `recording` не существовало вовсе.
    func test_k28_aHighEstimateStartsNoRecordingNowThatRecordingExists() async throws {
        for policy in [AppSettings.RecordingPolicy.auto, .ask, .manual] {
            let stand = try bench(policy: policy)
            let event = try SessionMachineFixtures.event()
            stand.seed(event)
            stand.allowCaptureStart()
            await stand.machine.start(now: moment.addingTimeInterval(60))
            await stand.machine.tick(now: moment.addingTimeInterval(60))
            for index in 0..<5 {
                await stand.deliver(SessionMachineFixtures.signal(
                    kind: .clientRunning, weight: 0.4, appKey: "client-\(index)",
                    observedAt: moment.addingTimeInterval(60), pid: Int32(800 + index)
                ))
            }
            await stand.machine.tick(now: moment.addingTimeInterval(60))

            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertGreaterThan(live.estimate, 0.9, "\(policy): оценка выше 0,9")
            XCTAssertEqual(live.state, .awaitingSignal, "\(policy): и записи не начато")
            XCTAssertNil(live.recordingId)
            await stand.machine.stop()
        }
    }

    // MARK: - Оснастка

    private func assertTerminal(
        _ stand: SessionMachineBench,
        state: MeetingStatus,
        _ command: () async throws -> Void
    ) async {
        do {
            try await command()
            XCTFail("команда к терминальной сессии обязана броситься")
        } catch let error as SessionError {
            guard case let .sessionIsTerminal(_, thrown) = error else {
                XCTFail("брошено \(error), а не `sessionIsTerminal`")
                return
            }
            XCTAssertEqual(thrown, state, "и состояние в ошибке — фактическое")
        } catch {
            XCTFail("брошено не `SessionError`: \(error)")
        }
    }
}
