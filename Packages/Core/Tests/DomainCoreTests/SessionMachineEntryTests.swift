//  Вход в запись — К34 (строка 6), К36 (строка 8), К47 и К48 (§7.1).
//  MEE-300, часть B. Пункты плана MEE-288 §3, разделы Ж и З, части 3/8 и 4/8.
//
//  Форма всех четырёх одна: подаётся вход, на котором условие строки истинно целиком, —
//  переход обязан наступить; и вход, снимающий РОВНО ОДНУ клаузу, — переход обязан не
//  наступить. Клауз три, и снимаются они порознь: цели нет; цель занята чужой записью
//  (§7.1); политика цель не отдала (§8.2).
//
//  КАК ПОСТРОЕН ВЕКТОР «ЦЕЛЬ ЗАНЯТА», И ПОЧЕМУ НЕ ПРОЩЕ. Две сессии одного провайдера с
//  пересекающимися окнами дают не занятость, а СПОР (§5.4): цель относится к обеим, ни одна
//  её не получает, и §7.1 не читается вовсе. Поэтому занимает цель сессия `origin == .adHoc`:
//  у неё нет события, и сигнал с `provider != nil` к ней правилом 2 не относится ни в одном
//  состоянии — спора нет, а цель занята по-настоящему.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineEntryTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    /// Сессия встречи, доведённая до `armed` (до `e.start`) либо до `awaitingSignal`.
    private func standing(
        policy: AppSettings.RecordingPolicy,
        at offset: TimeInterval
    ) async throws -> (SessionMachineBench, MeetingEvent) {
        let stand = try bench(policy: policy)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        await stand.machine.start(now: moment.addingTimeInterval(offset))
        await stand.machine.tick(now: moment.addingTimeInterval(offset))
        return (stand, event)
    }

    // MARK: - К34 (строка 6: armed → recording, ранний вход)

    /// Положительный вектор: все три клаузы истинны, вход подаётся СТРОГО ДО `e.start` —
    /// ранний вход §8.1 разрешён, и это не дефект.
    func test_k34_row6_firesBeforeEventStartWhenAllThreeClausesHold() async throws {
        let (stand, _) = try await standing(policy: .auto, at: -60)
        stand.allowCaptureStart()
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(-60))

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "строка 6 срабатывает до `e.start`")
        XCTAssertNotNil(live.recordingId, "`recordingId` назначен при входе в `recording`")
        XCTAssertEqual(live.target?.appKey, "us.zoom.xos")

        let request = try XCTUnwrap(startRequests(stand).first)
        XCTAssertEqual(request.recordingId, live.recordingId, "К3: поле запроса равно полю снимка")
        XCTAssertEqual(request.meetingId, live.meetingId)
        XCTAssertEqual(request.group?.appKey, "us.zoom.xos")
        await stand.machine.stop()
    }

    /// Два отрицательных вектора из трёх — «цели нет» и «политика запрещает». Третий,
    /// «цель занята», подан отдельным тестом ниже: его оснастка вдвое длиннее.
    func test_k34_row6_noTargetAndAClosedPolicyEachStopItAlone() async throws {
        let (noTarget, _) = try await standing(policy: .auto, at: -60)
        noTarget.allowCaptureStart()
        await noTarget.machine.tick(now: moment.addingTimeInterval(-60))
        let idle = try unwrap(await noTarget.machine.sessions().first)
        XCTAssertEqual(idle.state, .armed, "цели нет — строка 6 не срабатывает")
        await noTarget.machine.stop()

        let (manual, _) = try await standing(policy: .manual, at: -60)
        manual.allowCaptureStart()
        await manual.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-60)
        ))
        await manual.machine.tick(now: moment.addingTimeInterval(-60))
        let held = try unwrap(await manual.machine.sessions().first)
        XCTAssertEqual(held.state, .armed, "`.manual` — строка 6 не срабатывает")
        XCTAssertEqual(held.target?.appKey, "us.zoom.xos", "цель при этом есть")
        XCTAssertEqual(startRequests(manual).count, 0, "и захват не зван ни разу")
        await manual.machine.stop()
    }

    // MARK: - К36 (строка 8: awaitingSignal → recording)

    /// Условие строки 8 — ТО ЖЕ САМОЕ, что в строке 6, дословно. Один и тот же набор
    /// подаётся в оба состояния и требует одинакового ответа: два места, где написано одно
    /// условие, расходятся молча, и ловит это только парная подача.
    func test_k36_row8_answersExactlyAsRow6OnTheSameVectors() async throws {
        let cases: [(AppSettings.RecordingPolicy, Bool, MeetingStatus)] = [
            (.auto, true, .recording),
            (.auto, false, .awaitingSignal),
            (.manual, true, .awaitingSignal),
            (.ask, true, .awaitingSignal)
        ]
        for (policy, hasTarget, expected) in cases {
            let (stand, _) = try await standing(policy: policy, at: 60)
            stand.allowCaptureStart()
            if hasTarget {
                await stand.deliver(SessionMachineFixtures.audioOutput(
                    appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
                ))
            }
            await stand.machine.tick(now: moment.addingTimeInterval(60))
            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.state, expected, "политика \(policy), цель \(hasTarget)")
            await stand.machine.stop()
        }
    }

    // MARK: - К34 (в) и К47 (инв. 13; §7.1)

    /// Занятость читается по ОБОИМ состояниям множества — `recording` и `stopping`.
    /// Реализация, смотрящая только на `recording`, зелена на первой половине и красна на
    /// второй, а `stopping` держится ровно то окно, в которое второй созвон и начинается.
    func test_k47_oneGroupOneRecordingInBothCapturingStates() async throws {
        for stopHolder in [false, true] {
            let (stand, event, holder) = try await standWithAdHocHolder()
            if stopHolder {
                stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
                let snapshot = try unwrap(await stand.machine.session(id: holder))
                try await stand.machine.stopRecording(
                    recordingId: try XCTUnwrap(snapshot.recordingId), now: moment.addingTimeInterval(20)
                )
                let stopping = try unwrap(await stand.machine.session(id: holder))
                XCTAssertEqual(stopping.state, .stopping, "держатель переведён в `stopping`")
            }
            try await openWindowOfSecondSession(stand)

            let owner = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
            XCTAssertEqual(owner.state, .armed, "вторая сессия не пишет: цель занята (§7.1)")
            XCTAssertEqual(owner.target?.appKey, "us.zoom.xos", "цель у неё при этом есть")
            let capturing = await stand.machine.sessions()
                .filter { $0.state == .recording || $0.state == .stopping }
            XCTAssertEqual(capturing.count, 1, "двух записей одной группы нет")
            XCTAssertEqual(startRequests(stand).count, 1, "второй `start` захвата не зван")
            await stand.machine.stop()
        }
    }

    // MARK: - К48 (§7.1, вторая половина; `SessionError.alreadyRecording`)

    /// Команда, упёршаяся в занятую цель, бросает `alreadyRecording(sessionId:)`, и
    /// `sessionId` в ошибке — ТОЙ СЕССИИ, КОТОРАЯ ЗАНИМАЕТ ЦЕЛЬ, а не той, что просит:
    /// по этому полю фасад показывает человеку, какая встреча уже пишется.
    func test_k48_commandThrowsAlreadyRecordingCarryingTheHolderSessionId() async throws {
        let (stand, event, holder) = try await standWithAdHocHolder()

        // Ad-hoc: цель не отнесена ни к одной сессии, и она занята.
        await assertAlreadyRecording(
            stand: stand, meetingId: nil, holder: holder,
            at: moment.addingTimeInterval(10), label: "ad-hoc"
        )

        // Сессия с событием: её окно открыто, цель к ней отнесена и занята.
        try await openWindowOfSecondSession(stand)
        await assertAlreadyRecording(
            stand: stand, meetingId: event.id, holder: holder,
            at: moment.addingTimeInterval(3000), label: "сессия с событием"
        )
        await stand.machine.stop()
    }

    // MARK: - Оснастка

    /// Стенд, в котором цель `us.zoom.xos` ЗАНЯТА идущей записью ad-hoc-сессии, а вторая
    /// встреча того же провайдера ещё не взведена: её `armAt` — `moment + 3000`.
    private func standWithAdHocHolder() async throws -> (SessionMachineBench, MeetingEvent, UUID) {
        let stand = try bench(policy: .auto)
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600))
        stand.seed(event)
        stand.allowCaptureStart()
        await stand.machine.start(now: moment)
        await stand.machine.tick(now: moment)
        await stand.deliver(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: moment))
        await stand.machine.tick(now: moment)

        let prompt = try unwrap(await stand.machine.prompts().first)
        try await stand.machine.answer(promptId: prompt.promptId, .record, now: moment)
        let holder = try unwrap(await stand.machine.session(id: prompt.sessionId))
        XCTAssertEqual(holder.state, .recording, "ad-hoc держит цель строкой 16")
        XCTAssertEqual(holder.origin, .adHoc)
        return (stand, event, prompt.sessionId)
    }

    /// Довести вторую встречу до её окна: цель к ней отнесётся правилом 2, спора при этом
    /// не будет — к ad-hoc-держателю сигнал с провайдером не относится ни одним правилом.
    private func openWindowOfSecondSession(_ stand: SessionMachineBench) async throws {
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(3000)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(3000))
    }

    private func startRequests(_ stand: SessionMachineBench) -> [CaptureRequest] {
        stand.capture.recordedCalls.compactMap { call -> CaptureRequest? in
            if case let .start(request) = call { return request }
            return nil
        }
    }

    private func assertAlreadyRecording(
        stand: SessionMachineBench,
        meetingId: UUID?,
        holder: UUID,
        at now: Date,
        label: String
    ) async {
        do {
            _ = try await stand.machine.startRecording(meetingId: meetingId, now: now)
            XCTFail("\(label): команда обязана броситься, а не вернуть номер")
        } catch let error as SessionError {
            XCTAssertEqual(error, .alreadyRecording(sessionId: holder), "\(label): номер — занимающей")
        } catch {
            XCTFail("\(label): брошено не `SessionError`: \(error)")
        }
    }
}
