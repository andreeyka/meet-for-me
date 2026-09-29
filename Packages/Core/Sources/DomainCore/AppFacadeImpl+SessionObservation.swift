//  AppFacadeImpl — публикация `AppStatus` на смене состояния сессии (C-016 v10,
//  §«Поведение»; MEE-456) и `meetingsChanged` на смене `RecordingStatus` (инв. 34; MEE-492).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ТЕКСТ КОНТРАКТА. «`AppStatus` пересчитывается и публикуется не реже чем при каждом
//  изменении: старт и стоп записи, смена состояния сессии, …». Источник смены —
//  `SessionCoordinator.changes()` (C-018 §3.1). Порядок задаёт инв. 34 (б) (C-016 v12):
//  при смене `RecordingStatus` `meetingsChanged` идёт не позже `statusChanged` того же
//  изменения. Инв. 15 («до возврата управления») — про команды, и для
//  `startRecording`/`stopRecording`/`skipMeeting` уже исполнен в них самих.
//
//  ЧТО СЧИТАЕТСЯ СМЕНОЙ. `.session(snapshot)` с `state`, отличным от последнего известного
//  фасаду для этого `sessionId` (либо сессия видна впервые). Снимок с тем же `state` (новая
//  `estimate`/`target`/`updatedAt`) — не «смена состояния сессии», и в `AppStatus` из него
//  не видно ничего: `recordingId` у сессии появляется только вместе со входом в `.recording`
//  и дальше не меняется (C-018 §1.1). `.promptRaised`/`.promptWithdrawn` — не смена
//  состояния сессии, и спросов в `AppStatus` нет.
//
//  `meetingsChanged` — ТОЛЬКО НА СМЕНЕ `RecordingStatus` (MEE-492, инв. 34 (б)), а не на всякой
//  смене состояния сессии: `scheduled → armed → awaitingSignal` и `processing → ready` записи не
//  меняют. Статус записи выводится из состояния сессии (`impliedRecordingStatus`). Команда
//  (`startRecording`/`stopRecording`) и наблюдение сессий сообщают об одном и том же изменении
//  разными путями, и порядок их прихода не задан; поэтому оба идут через
//  `publishMeetingsChangedIfAdvanced` — событие публикуется один раз на каждый новый статус записи.
//
//  ПОЧЕМУ `status()` ПОСЛЕ ПРИХОДА СНИМКА ВИДИТ НОВОЕ. C-018 инв. 18: машина пишет
//  `setStatus` в хранилище ПРЕЖДЕ публикации снимка — `upcoming[].status` (из
//  `MeetingRepository`) и `activeSession` (из `sessions()`) к этому моменту уже новые.
//
//  Терминальная сессия (`ready`/`failed`/`skipped`) публикуется и забывается: `sessions()`
//  её больше не отдаёт, и держать её состояние фасаду незачем.

import Foundation

extension AppFacadeImpl {

    func handleSessionChange(_ change: SessionChange) async {
        guard case .session(let snapshot) = change else { return }
        guard knownSessionStates[snapshot.sessionId] != snapshot.state else { return }
        if snapshot.state.isTerminalSession {
            knownSessionStates[snapshot.sessionId] = nil
        } else {
            knownSessionStates[snapshot.sessionId] = snapshot.state
        }
        // Инв. 34 (б), IR-146: `meetingsChanged` не позже `statusChanged` — и только если
        // `RecordingStatus` записи этой сессии действительно сменился (MEE-492).
        if let recordingId = snapshot.recordingId, let status = Self.impliedRecordingStatus(snapshot.state) {
            publishMeetingsChangedIfAdvanced(recordingId: recordingId, to: status)
        }
        publish(.statusChanged(await status()))
    }

    /// Публикует `meetingsChanged`, если `status` — новый для записи статус (дальше по порядку
    /// `recording → stopping → finalized | failed`, чем уже опубликованный). Повтор того же
    /// статуса вторым путём (команда и снимок сессии) и запоздалый старый статус — молчат.
    func publishMeetingsChangedIfAdvanced(recordingId: UUID, to status: RecordingStatus) {
        if let published = publishedRecordingStatuses[recordingId],
           Self.rank(status) <= Self.rank(published) {
            return
        }
        publishedRecordingStatuses[recordingId] = status
        publish(.meetingsChanged)
    }

    /// `RecordingStatus` записи сессии в этом состоянии (C-018 §7): `recording`/`stopping` —
    /// захват идёт или останавливается; `processing`/`ready` — запись сохранена `.finalized`
    /// (вход в `processing` — только после сохранения, строка 12); `failed` — запись упала.
    /// Состояния до записи и `skipped` записи не имеют — `nil`.
    static func impliedRecordingStatus(_ state: MeetingStatus) -> RecordingStatus? {
        switch state {
        case .recording: return .recording
        case .stopping: return .stopping
        case .processing, .ready: return .finalized
        case .failed: return .failed
        case .scheduled, .armed, .awaitingSignal, .skipped: return nil
        }
    }

    private static func rank(_ status: RecordingStatus) -> Int {
        switch status {
        case .recording: return 0
        case .stopping: return 1
        case .finalized, .failed: return 2
        }
    }
}
