//  Занятая цель и третья причина клаузы строки 9 — К94.
//  MEE-307, часть C. Пункты плана MEE-288 §3, раздел Л.
//
//  ПУНКТ НЕ ПОДАВАЛСЯ ДЕРЕВОМ НИ ОДНИМ ВЕКТОРОМ: он требует, чтобы держателем занятой цели
//  выступала AD-HOC-СЕССИЯ, а до правила `1а` §5.4 у ad-hoc-сессии не было цели вовсе — и
//  §7.1 мерил её занятость по `nil`. Клауза Входа названа самим пунктом и не заменяема:
//  две сессии событий одного провайдера дали бы не занятость, а СПОР, и `skipped` пришёл бы
//  по ПЕРВОЙ причине клаузы («цели нет»), то есть мимо проверяемого входа.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineHeldTargetTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К94 (§7.1; строка 9, третья причина клаузы)

    /// Цель ЕСТЬ, актуальна, политика её ОТДАЁТ — и она ЗАНЯТА идущей записью другой
    /// сессии. Держателем выступает AD-HOC-СЕССИЯ, и это клауза Входа, а не деталь
    /// оснастки: две сессии событий одного провайдера дали бы не занятость, а СПОР, и
    /// `skipped` пришёл бы по ПЕРВОЙ причине клаузы, то есть мимо проверяемого входа.
    ///
    /// Ad-hoc-держатель спора не заводит, и довод — правило `1а` §5.4: оно стоит раньше
    /// правил 2 и 3, и сторон спора не прибавляет ни одной.
    func test_k94_aHeldTargetSendsTheSessionToSkippedByTheThirdCause() async throws {
        let settings = SessionMachineFixtures.settings()
        let stand = try bench(policy: .auto)
        stand.allowCaptureStart()
        let event = try SessionMachineFixtures.event(provider: "zoom")
        stand.seed(event)

        // ДЕРЖАТЕЛЬ ЗАВОДИТСЯ ДО `armAt` СОБЫТИЯ, И ЭТО ЧАСТЬ ВХОДА, А НЕ ОСНАСТКА: пока
        // окно закрыто, правило 2 к сессии события сигнала не относит, и тот есть вход
        // §8.6 (правило 4). Команда подаётся до первого `tick`, чтобы сессию завела
        // строка 16 без спроса (К44).
        let before = SessionMachineRules.arm(for: event, settings: settings)
            .armAt.addingTimeInterval(-100)
        await stand.machine.start(now: before)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: before, provider: "zoom"
        ))
        let holderRecording = try await stand.machine.startRecording(meetingId: nil, now: before)
        let holder = try unwrap(await stand.machine.sessions().first { $0.origin == .adHoc })
        XCTAssertEqual(holder.state, .recording, "оснастка: ad-hoc-держатель пишет")
        XCTAssertEqual(holder.recordingId, holderRecording)

        let grace = SessionMachineRules.arm(for: event, settings: settings).graceEndsAt
        // Цель подаётся ЗАНОВО перед каждым проверяемым моментом: иначе к `graceEndsAt` она
        // старше `signalTtlSeconds` и вход не подан вовсе (К51, К52).
        let earlier = grace.addingTimeInterval(-30)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: earlier, provider: "zoom"
        ))
        await stand.machine.tick(now: earlier)
        let waiting = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
        XCTAssertEqual(waiting.state, .awaitingSignal, "до `graceEndsAt` стоит и ждёт")
        XCTAssertEqual(waiting.target?.appKey, "us.zoom.xos", "при ЗАПОЛНЕННОЙ и актуальной цели")

        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: grace, provider: "zoom"
        ))
        await stand.machine.tick(now: grace)

        let ofMeeting = await stand.machine.sessions().first { $0.meetingId == event.id }
        XCTAssertNil(ofMeeting, "в САМ момент `graceEndsAt` сессия ушла в `skipped` строкой 9")
        XCTAssertEqual(
            stand.meetings.storedRecords.first?.status, .skipped,
            "и хранимый `MeetingStatus` записан `setStatus`-ом (К81)"
        )
        let keeper = try unwrap(await stand.machine.sessions().first { $0.origin == .adHoc })
        XCTAssertEqual(keeper.state, .recording, "держатель при этом продолжает писать")
        XCTAssertEqual(keeper.recordingId, holderRecording, "его `recordingId` не меняется (К3)")
        XCTAssertEqual(keeper.target?.appKey, "us.zoom.xos", "и его цель остаётся заполненной")
        XCTAssertEqual(
            stand.log.count(port: "AudioCapturePort", method: "start(_:)"), 1,
            "`CaptureRequest` наружу не ушёл ни разу сверх записи держателя"
        )
        await stand.machine.stop()
    }

    /// Отрицательный (а): держатель выходит из множества `{recording, stopping}` ДО
    /// `graceEndsAt`, цель освобождается — сессия обязана уйти в `recording` СТРОКОЙ 8, а
    /// не в `skipped`.
    func test_k94_a_negative_aFreedTargetSendsTheSessionToRecordingByRow8() async throws {
        let settings = SessionMachineFixtures.settings()
        let stand = try bench(policy: .auto)
        stand.allowCaptureStart()
        let event = try SessionMachineFixtures.event(provider: "zoom")
        stand.seed(event)
        let arm = SessionMachineRules.arm(for: event, settings: settings)
        let before = arm.armAt.addingTimeInterval(-100)

        await stand.machine.start(now: before)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: before, provider: "zoom"
        ))
        _ = try await stand.machine.startRecording(meetingId: nil, now: before)
        let holder = await stand.machine.sessions().first { $0.origin == .adHoc }
        XCTAssertNotNil(holder, "оснастка: держатель пишет")

        // ДЕРЖАТЕЛЬ ВЫХОДИТ ИЗ МНОЖЕСТВА `{recording, stopping}` ДО `graceEndsAt` — И
        // ВЫХОДИТ ОН СТРОКАМИ 10 И 12, А НЕ ОТКАЗОМ ЗАХВАТА. Довод не вкусовой: событие
        // `CaptureEvent.failed` порту захвата принадлежит ЦЕЛИКОМ, а не сессии (порт один
        // на приложение), и живёт оно до конца того же `tick` — то есть строка 11 увела бы
        // в `failed` и сессию встречи, едва та войдёт в `recording` тем же ходом. Вход
        // пункта — «цель освободилась», а не «захват отказал», и подаётся он остановкой.
        let holderRecording = try unwrap(holder?.recordingId)
        let freeing = arm.startsAt.addingTimeInterval(30)
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        try await stand.machine.stopRecording(recordingId: holderRecording, now: freeing)
        await stand.deliver(CaptureEvent.stopped(
            try SessionMachineFixtures.manifest(recordingId: holderRecording, meetingId: nil)
        ))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: freeing, provider: "zoom"
        ))
        await stand.machine.tick(now: freeing)

        let freed = try unwrap(await stand.machine.sessions().first { $0.origin == .adHoc })
        XCTAssertEqual(
            freed.state, .processing,
            "оснастка: держатель вышел из множества `{recording, stopping}` строкой 12"
        )

        // Цель свободна с этого хода, и строка 8 срабатывает на БЛИЖАЙШЕМ `tick` после
        // освобождения (инвариант 14): в тот ход, когда держатель ещё держал цель, она
        // была ложна второй клаузой §7.1.
        let after = freeing.addingTimeInterval(10)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: after, provider: "zoom"
        ))
        await stand.machine.tick(now: after)

        let ofMeeting = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
        XCTAssertEqual(ofMeeting.state, .recording, "цель освободилась — строка 8, а не строка 9")
        await stand.machine.stop()
    }

    /// Отрицательный (б): держатель занимает ДРУГОЙ `appKey` — переход в `skipped` не
    /// наступает, и сессия уходит в `recording` своей целью.
    func test_k94_b_negative_aHolderOfAnotherAppKeyBlocksNothing() async throws {
        let settings = SessionMachineFixtures.settings()
        let stand = try bench(policy: .auto)
        stand.allowCaptureStart()
        let event = try SessionMachineFixtures.event(provider: "zoom")
        stand.seed(event)
        let arm = SessionMachineRules.arm(for: event, settings: settings)
        let before = arm.armAt.addingTimeInterval(-100)

        await stand.machine.start(now: before)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "com.microsoft.teams", observedAt: before, provider: nil
        ))
        _ = try await stand.machine.startRecording(meetingId: nil, now: before)

        let at = arm.startsAt.addingTimeInterval(30)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: at, provider: "zoom"
        ))
        await stand.machine.tick(now: at)

        let ofMeeting = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
        XCTAssertEqual(ofMeeting.state, .recording, "чужая занятость не мешает ни на сколько")
        await stand.machine.stop()
    }
}
