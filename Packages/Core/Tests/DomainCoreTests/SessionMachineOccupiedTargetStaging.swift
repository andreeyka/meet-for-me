//  Стенд «цель занята» — общая оснастка К47, К48 и К100 (§7.1, §8.2 издание v8).
//  MEE-300, часть B; MEE-341.
//
//  ВЫНЕСЕНА В ОТДЕЛЬНЫЙ ФАЙЛ, а не оставлена приватной `SessionMachineEntryTests`, по двум
//  доводам. Первый механический: `--strict` линта считает файл длиннее четырёхсот строк
//  нарушением (`file_length`), а К48 и К100 вместе с этой оснасткой давали больше пятисот.
//  Второй — по существу: К48 и К100 читают ОДИН И ТОТ ЖЕ вход «цель занята» РАЗНЫМИ файлами
//  тестов (`docs/process.md` §5, «пара, которую нельзя развести по разным прогонам» — вход
//  общий, а прогон свой), и второго описания одной оснастки заводить незачем.
//
//  КАК ПОСТРОЕН ВЕКТОР «ЦЕЛЬ ЗАНЯТА» — тот же довод, что и раньше в `SessionMachineEntryTests`:
//  держит цель сессия `origin == .adHoc`, к которой сигнал с `provider != nil` не относится
//  ни одним правилом, — и потому занятость не превращается в спор §5.4.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

/// Стенд, в котором цель `us.zoom.xos` ЗАНЯТА идущей записью ad-hoc-держателя, а вторая
/// встреча ("владелец") доведена до одного из четырёх состояний §7.
struct SessionMachineOccupiedStand {
    let stand: SessionMachineBench
    let event: MeetingEvent
    let holder: UUID

    private static func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    /// Держатель занял "us.zoom.xos"; владелец — вторая встреча того же провайдера, ещё не
    /// взведённая: её `armAt` — `moment + 3000`, `e.start` — `moment + 3600`.
    static func withAdHocHolder(from moment: Date) async throws -> SessionMachineOccupiedStand {
        let stand = try bench()
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600))
        stand.seed(event)
        stand.allowCaptureStart()
        await stand.machine.start(now: moment)
        await stand.machine.tick(now: moment)
        await stand.deliver(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: moment))
        await stand.machine.tick(now: moment)

        let prompt = try unwrap(await stand.machine.prompts().first)
        try await stand.machine.answer(promptId: prompt.promptId, .record(sessionId: prompt.sessionId), now: moment)
        let holder = try unwrap(await stand.machine.session(id: prompt.sessionId))
        XCTAssertEqual(holder.state, .recording, "оснастка: ad-hoc держит цель строкой 16")
        XCTAssertEqual(holder.origin, .adHoc)
        return SessionMachineOccupiedStand(stand: stand, event: event, holder: prompt.sessionId)
    }

    /// Владелец доведён до `armed`: окно открыто (`armAt`), `e.start` ещё не наступил.
    static func armedOwner(from moment: Date) async throws -> SessionMachineOccupiedStand {
        let staged = try await withAdHocHolder(from: moment)
        await staged.stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(3000)
        ))
        await staged.stand.machine.tick(now: moment.addingTimeInterval(3000))
        let owner = try unwrap(await staged.stand.machine.sessions().first { $0.meetingId == staged.event.id })
        XCTAssertEqual(owner.state, .armed, "оснастка: окно открыто, `e.start` не наступил — цель занята")
        return staged
    }

    /// Владелец доведён до `awaitingSignal`: `e.start` уже наступил (строка 7 — «`now ≥
    /// e.start`, а цель занята»), окно при этом ещё открыто.
    static func awaitingOwner(from moment: Date) async throws -> SessionMachineOccupiedStand {
        let staged = try await withAdHocHolder(from: moment)
        await staged.stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(3600)
        ))
        await staged.stand.machine.tick(now: moment.addingTimeInterval(3600))
        let owner = try unwrap(await staged.stand.machine.sessions().first { $0.meetingId == staged.event.id })
        XCTAssertEqual(owner.state, .awaitingSignal, "оснастка: `e.start` наступил, цель занята — строка 7")
        return staged
    }

    /// Владелец НЕ ТИКНУТ мимо своего `armAt`: состояние остаётся `.scheduled`, хотя вход
    /// «занята цель» уже наступил бы, читай его команда сроками свежими, а не хранимым
    /// состоянием (§«Поведение»).
    static func scheduledOwner(from moment: Date) async throws -> SessionMachineOccupiedStand {
        let staged = try await withAdHocHolder(from: moment)
        let owner = try unwrap(await staged.stand.machine.sessions().first { $0.meetingId == staged.event.id })
        XCTAssertEqual(owner.state, .scheduled, "оснастка: окно ещё не открыто ни одним `tick`")
        return staged
    }

    /// Владелец записал на СВОЕЙ цели `owner.target` и доведён до `processing` обычным
    /// путём (строки 6 и 12), а `us.zoom.xos` сверх того занята держателем, заведённым
    /// ЗАДОЛГО ДО начала — раньше всей истории владельца, потому что время машины не идёт
    /// назад: `start(now:)` зовётся здесь ровно один раз.
    static func processingOwner(from moment: Date) async throws -> SessionMachineOccupiedStand {
        let stand = try bench()
        let event = try SessionMachineFixtures.event(start: moment)
        stand.seed(event)
        stand.allowCaptureStart()
        stand.queue.setNextSubmitIds([UUID(), UUID(), UUID(), UUID()])
        // Исход `stop()` задан заранее: строка 10 зовёт его сама, и незаданный исход увёл бы
        // сессию строкой 13 в `failed` вместо `stopping` (`SessionMachineStand.recording`).
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)

        // Держатель — задолго до окна владельца: `armAt` владельца лежит далеко в будущем
        // относительно `early`, и потому сигнал ей не отнесён — условие ad-hoc-заведения
        // истинно.
        let early = moment.addingTimeInterval(-10000)
        await stand.machine.start(now: early)
        await stand.machine.tick(now: early)
        await stand.deliver(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: early))
        await stand.machine.tick(now: early)
        let prompt = try unwrap(await stand.machine.prompts().first)
        try await stand.machine.answer(promptId: prompt.promptId, .record(sessionId: prompt.sessionId), now: early)
        let holder = try unwrap(await stand.machine.session(id: prompt.sessionId))
        XCTAssertEqual(holder.state, .recording, "оснастка: ad-hoc держит цель строкой 16")

        let armAt = moment.addingTimeInterval(-600)
        await stand.machine.tick(now: armAt)
        await stand.deliver(SessionMachineFixtures.audioOutput(appKey: "owner.target", observedAt: armAt))
        await stand.machine.tick(now: armAt)
        let recording = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
        XCTAssertEqual(recording.state, .recording, "оснастка: владелец записывает на своей цели")
        let recordingId = try unwrap(recording.recordingId)

        try await stand.machine.stopRecording(recordingId: recordingId, now: armAt.addingTimeInterval(10))
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: event.id)
        await stand.deliver(CaptureEvent.stopped(manifest))
        await stand.machine.tick(now: armAt.addingTimeInterval(20))
        let processing = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
        XCTAssertEqual(processing.state, .processing, "оснастка: владелец в обработке")

        return SessionMachineOccupiedStand(stand: stand, event: event, holder: prompt.sessionId)
    }
}

/// Стенд БЕЗ держателя: владелец в `processing` на своей цели `owner.target`, а
/// `us.zoom.xos` СВОБОДНА — ею никто не занят (К100, исход (3)).
struct SessionMachineFreeTargetStand {
    let stand: SessionMachineBench
    let event: MeetingEvent

    static func processingOwner(from moment: Date) async throws -> SessionMachineFreeTargetStand {
        let stand = SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: .auto),
            weights: try SessionMachineFixtures.weights()
        )
        let event = try SessionMachineFixtures.event(start: moment)
        stand.seed(event)
        stand.allowCaptureStart()
        stand.queue.setNextSubmitIds([UUID(), UUID(), UUID(), UUID()])
        // Исход `stop()` задан заранее — см. довод в `SessionMachineOccupiedStand.processingOwner`.
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)

        let armAt = moment.addingTimeInterval(-600)
        await stand.machine.start(now: armAt)
        await stand.machine.tick(now: armAt)
        await stand.deliver(SessionMachineFixtures.audioOutput(appKey: "owner.target", observedAt: armAt))
        await stand.machine.tick(now: armAt)
        let recording = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
        XCTAssertEqual(recording.state, .recording, "оснастка: владелец записывает на своей цели")
        let recordingId = try unwrap(recording.recordingId)

        try await stand.machine.stopRecording(recordingId: recordingId, now: armAt.addingTimeInterval(10))
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: event.id)
        await stand.deliver(CaptureEvent.stopped(manifest))
        await stand.machine.tick(now: armAt.addingTimeInterval(20))
        let processing = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
        XCTAssertEqual(processing.state, .processing, "оснастка: владелец в обработке")

        return SessionMachineFreeTargetStand(stand: stand, event: event)
    }
}

/// Довести владельца стенда `withAdHocHolder(from:)` до его окна (`armed`): цель отнесётся
/// правилом 2, спора при этом не будет — к ad-hoc-держателю сигнал с провайдером не
/// относится ни одним правилом.
func openWindowOfSecondSession(_ stand: SessionMachineBench, at moment: Date) async {
    await stand.deliver(SessionMachineFixtures.audioOutput(
        appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(3000)
    ))
    await stand.machine.tick(now: moment.addingTimeInterval(3000))
}

/// Команда, упёршаяся в занятую цель, бросает `alreadyRecording(sessionId:)`, и `sessionId`
/// в ошибке — ТОЙ СЕССИИ, КОТОРАЯ ЗАНИМАЕТ ЦЕЛЬ, а не той, что просит (К48, К100).
func assertAlreadyRecording(
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
