//  AppFacadeImpl — `AppStatus.activeSession` (C-016 v11, §1 `ActiveSessionView`, инв. 27 и 30;
//  группа Р плана MEE-410, К42; MEE-449, MEE-462).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ОТКУДА КАКОЕ ПОЛЕ. Сессия и её идентичность (`recordingId`, `meetingId`, `state`) — из
//  `SessionCoordinator.sessions()` (C-018 §3.1). Состав захвата — инв. 27: три поля равны
//  полям последнего `CapturedProcessSnapshot` (C-004), который приходит только событием
//  `CaptureEvent.capturedProcessesChanged` потока `AudioCapturePort.events()`. Уровни —
//  §«Поведение»: событием потока (`CaptureEvent.levels`). Остальное — инв. 30 (v11, IR-142):
//   (а) сессия — в `recording` (`stopping` идущей записью не считается, тот же признак, что у
//       инв. 9); если их видно две (окно отката), берётся та, чей `recordingId` равен
//       `recordingId` последнего наблюдённого `.started`, иначе первая в порядке `sessions()`;
//   (б) `startedAt` — `CaptureStarted.startedAt` этой записи, до её `.started` — `enteredStateAt`;
//   (в) `title` — `MeetingEvent.title`; без `meetingId`, без строки встречи и при отказе
//       чтения — «Созвон без события» (`status()` не `throws`, отказ не бросается);
//   (г) `requestedAppKey` до первого снимка — `CaptureStarted.captureGroupKey` той же записи,
//       до `.started` — `nil`; после снимка — поле снимка, в том числе законный `nil`.
//
//  СНИМОК ПРИВЯЗАН К ЗАПИСИ. `CapturedProcessSnapshot` не несёт `recordingId`; его несёт
//  `CaptureStarted`. Наблюдение сбрасывается на каждом `.started` и отдаётся только сессии с
//  тем же `recordingId` — данные прошлой записи не выдаются за данные новой.
//
//  `CaptureEvent.failed` — инв. 31, источник (2): запись оборвалась сама → `AppEvent.failure`
//  с кодом `capture.<case>` тем же `wrap(_:)`, что у синхронного пути (инв. 24).

import Foundation

/// Последнее наблюдённое по потоку захвата — ровно то, что пришло, без пересчёта.
struct CaptureObservation: Sendable {
    var started: CaptureStarted?
    var snapshot: CapturedProcessSnapshot?
    var levels: CaptureLevels?

    var recordingId: UUID? { started?.recordingId }
}

extension AppFacadeImpl {

    /// Название встречи для сессии без события и для недоступной встречи (C-016 §1, инв. 30в).
    static let adHocSessionTitle = "Созвон без события"

    /// Одно событие захвата. `.statusChanged` — на смене состава: §«Поведение» называет
    /// «изменение состава захвата» среди поводов пересчитать и опубликовать `AppStatus`.
    func handleCaptureEvent(_ event: CaptureEvent) async {
        switch event {
        case .started(let started):
            captureObservation = CaptureObservation(started: started)
        case .capturedProcessesChanged(let snapshot):
            guard captureObservation.recordingId != nil else { return }
            captureObservation.snapshot = snapshot
            publish(.statusChanged(await status()))
        case .levels(let levels):
            guard captureObservation.recordingId != nil else { return }
            captureObservation.levels = levels
        case .failed(let error):
            // Инв. 31 (2): ровно один `failure` на событие-источник.
            await publishFailure(error)
        case .inputDeviceChanged, .inputFormatChanged, .discontinuity, .systemSilent,
             .promptPending, .permissionObserved, .paused, .resumed, .stopped:
            return
        }
    }

    /// К42, инв. 27 и 30. `nil`, пока идущей записи нет.
    func activeSessionView() async -> ActiveSessionView? {
        let recording = await sessionCoordinator.sessions().filter { $0.state == .recording && $0.recordingId != nil }
        let lastStarted = captureObservation.recordingId
        guard let session = recording.first(where: { $0.recordingId == lastStarted }) ?? recording.first,
              let recordingId = session.recordingId else {
            return nil
        }
        let observed = lastStarted == recordingId ? captureObservation : CaptureObservation()
        let snapshot = observed.snapshot
        return ActiveSessionView(
            recordingId: recordingId,
            meetingId: session.meetingId,
            title: await activeSessionTitle(meetingId: session.meetingId),
            state: session.state,
            startedAt: observed.started?.startedAt ?? session.enteredStateAt,
            requestedAppKey: snapshot.map(\.requestedAppKey) ?? observed.started?.captureGroupKey,
            capturedProcesses: snapshot?.processes ?? [],
            containsUnrequested: snapshot?.containsUnrequested ?? false,
            micLevel: observed.levels?.mic,
            systemLevel: observed.levels?.system
        )
    }

    /// Инв. 30(в): встреча без `meetingId`, без строки и с отказом чтения — одно название.
    private func activeSessionTitle(meetingId: UUID?) async -> String {
        guard let meetingId,
              let record = try? await meetingRepository.meeting(id: meetingId) else {
            return Self.adHocSessionTitle
        }
        return record.event.title
    }
}
