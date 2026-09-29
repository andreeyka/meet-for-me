//  AppFacadeImpl — `AppStatus.activeSession` (C-016 v10, §1 `ActiveSessionView`, инв. 27;
//  группа Р плана MEE-410, К42; MEE-449).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ОТКУДА КАКОЕ ПОЛЕ. Сессия и её идентичность (`recordingId`, `meetingId`, `state`) — из
//  `SessionCoordinator.sessions()` (C-018 §3.1): «решения … принимает `SessionCoordinator`»
//  (C-016 §«Поведение»). Состав захвата — инв. 27 дословно: три поля «равны полям
//  `processes`, `containsUnrequested` и `requestedAppKey` **последнего** снимка состава
//  захвата (`CapturedProcessSnapshot`, C-004)»; такой снимок в C-004 приходит только
//  событием `CaptureEvent.capturedProcessesChanged` потока `AudioCapturePort.events()` —
//  `SessionCoordinator` его не отдаёт. Уровни — §«Поведение»: «сам уровень приходит событием
//  потока, а не свойством порта» (`CaptureEvent.levels`). Фасад ничего из этого не
//  вычисляет — только проводит.
//
//  «ИДУЩАЯ ЗАПИСЬ» — ТОТ ЖЕ ПРИЗНАК, ЧТО У ИНВ. 9. Инв. 27: «пока идущей записи нет,
//  `activeSession` равен `nil`»; инв. 9 употребляет тот же термин («при уже идущей записи»),
//  и `startRecording` (`AppFacadeImpl+Recording.swift`) исполняет его как `state ==
//  .recording`. Здесь тот же признак — второго определения одного термина фасад не заводит.
//
//  СНИМОК ПРИВЯЗАН К ЗАПИСИ. `CapturedProcessSnapshot` не несёт `recordingId`; его несёт
//  `CaptureStarted` события `.started`. Наблюдение сбрасывается на каждом `.started` и
//  отдаётся только сессии с тем же `recordingId` — снимок прошлой записи не выдаётся за
//  состав новой: до первого снимка новой записи — `[]`/`false` («ещё не наблюдали», инв. 27).

import Foundation

/// Последнее наблюдённое по потоку захвата — ровно то, что пришло, без пересчёта.
struct CaptureObservation: Sendable {
    var recordingId: UUID?
    var snapshot: CapturedProcessSnapshot?
    var levels: CaptureLevels?
}

extension AppFacadeImpl {

    /// Название встречи для сессии без события (`ActiveSessionView.title`, C-016 §1).
    static let adHocSessionTitle = "Созвон без события"

    /// Одно событие захвата. `.statusChanged` — на смене состава: §«Поведение» называет
    /// «изменение состава захвата» среди поводов пересчитать и опубликовать `AppStatus`.
    func handleCaptureEvent(_ event: CaptureEvent) async {
        switch event {
        case .started(let started):
            captureObservation = CaptureObservation(recordingId: started.recordingId)
        case .capturedProcessesChanged(let snapshot):
            guard captureObservation.recordingId != nil else { return }
            captureObservation.snapshot = snapshot
            publish(.statusChanged(await status()))
        case .levels(let levels):
            guard captureObservation.recordingId != nil else { return }
            captureObservation.levels = levels
        case .inputDeviceChanged, .inputFormatChanged, .discontinuity, .systemSilent,
             .promptPending, .permissionObserved, .paused, .resumed, .stopped, .failed:
            return
        }
    }

    /// К42. `nil`, пока идущей записи нет (инв. 27).
    func activeSessionView() async -> ActiveSessionView? {
        let sessions = await sessionCoordinator.sessions()
        guard let session = sessions.first(where: { $0.state == .recording }),
              let recordingId = session.recordingId else {
            return nil
        }
        let observed = captureObservation.recordingId == recordingId ? captureObservation : CaptureObservation()
        let snapshot = observed.snapshot
        return ActiveSessionView(
            recordingId: recordingId,
            meetingId: session.meetingId,
            title: await activeSessionTitle(meetingId: session.meetingId),
            state: session.state,
            // СТРОКА (вопрос к контракту, отчёт MEE-449): источник `startedAt` C-016 не
            // называет; взят момент входа сессии в `.recording` (C-018 `enteredStateAt`).
            startedAt: session.enteredStateAt,
            requestedAppKey: snapshot?.requestedAppKey,
            capturedProcesses: snapshot?.processes ?? [],
            containsUnrequested: snapshot?.containsUnrequested ?? false,
            micLevel: observed.levels?.mic,
            systemLevel: observed.levels?.system
        )
    }

    /// «название встречи либо «Созвон без события»» (C-016 §1). СТРОКА (вопрос к контракту,
    /// отчёт MEE-449): встреча с `meetingId`, которую хранилище не отдало (нет строки либо
    /// отказ чтения — `status()` не `throws`), получает то же название, что сессия без события.
    private func activeSessionTitle(meetingId: UUID?) async -> String {
        guard let meetingId,
              let record = try? await meetingRepository.meeting(id: meetingId) else {
            return Self.adHocSessionTitle
        }
        return record.event.title
    }
}
