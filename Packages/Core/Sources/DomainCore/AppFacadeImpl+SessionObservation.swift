//  AppFacadeImpl — публикация `AppStatus` на смене состояния сессии (C-016 v10,
//  §«Поведение»; MEE-456) и `meetingsChanged` на смене строки списка (инв. 34; MEE-492).
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
//  КОГДА `meetingsChanged` (MEE-492, решение РП по ревью #213, вариант (а)). Список недели —
//  строки встреч (`MeetingListItem.status` — `MeetingStatus`) и ad-hoc записей
//  (`RecordingSummary.status` — `RecordingStatus`). Событие публикуется, когда у снимка
//  сменилось хоть одно из двух: `RecordingStatus` записи (инв. 34 (б); выводится из состояния
//  сессии — `impliedRecordingStatus`) или `MeetingStatus` встречи (есть `meetingId`). Смена
//  состояния ad-hoc сессии без смены статуса записи (`processing → ready`) события не даёт.
//  Команды (`startRecording`/`stopRecording`/`skipMeeting`) и снимок сессии сообщают об одном
//  изменении разными путями в незаданном порядке; все они идут через
//  `publishMeetingsChangedIfRowsChanged` — пара «статус записи, статус встречи» публикуется
//  один раз.
//
//  ПОЧЕМУ `status()` ПОСЛЕ ПРИХОДА СНИМКА ВИДИТ НОВОЕ. C-018 инв. 18: машина пишет
//  `setStatus` в хранилище ПРЕЖДЕ публикации снимка — `upcoming[].status` (из
//  `MeetingRepository`) и `activeSession` (из `sessions()`) к этому моменту уже новые.
//
//  Терминальная сессия (`ready`/`failed`/`skipped`) публикуется и забывается: `sessions()`
//  её больше не отдаёт, и держать её состояние и встречу её записи фасаду незачем. Последние
//  опубликованные статусы встречи и записи остаются: `skipMeeting`, `startRecording` и
//  `stopRecording` могут ответить после терминального снимка, и без них ответ дал бы лишнее
//  событие и вернул бы в кэши записи, которые больше никто не уберёт (MEE-494, Б1/Б2). Цена
//  названа: по одной паре «идентификатор — статус» на встречу и на запись за жизнь процесса.
//
//  КОМАНДЫ ЗАПИСИ (MEE-494, Б1/Б2). Ответ `startRecording`/`stopRecording` сообщает статус
//  записи; статус встречи из него выводится, только если статус записи продвинулся
//  (`publishCommandRowChange`). Иначе снимок того же или более позднего состояния уже
//  опубликован, и поздний ответ команды откатил бы строку встречи назад.

import Foundation

extension AppFacadeImpl {

    func handleSessionChange(_ change: SessionChange) async {
        guard case .session(let snapshot) = change else { return }
        guard knownSessionStates[snapshot.sessionId] != snapshot.state else { return }
        if let recordingId = snapshot.recordingId, let meetingId = snapshot.meetingId {
            recordingMeetingIds[recordingId] = meetingId
        }
        // Инв. 34 (б), IR-146: `meetingsChanged` не позже `statusChanged`.
        publishMeetingsChangedIfRowsChanged(
            recordingId: snapshot.recordingId,
            recordingStatus: Self.impliedRecordingStatus(snapshot.state),
            meetingId: snapshot.meetingId,
            meetingStatus: snapshot.state
        )
        if snapshot.state.isTerminalSession {
            knownSessionStates[snapshot.sessionId] = nil
            // Опубликованный статус записи остаётся (MEE-494, Б1/Б2): поздний ответ
            // `startRecording`/`stopRecording` сравнивается с ним и молчит.
            if let recordingId = snapshot.recordingId { recordingMeetingIds[recordingId] = nil }
        } else {
            knownSessionStates[snapshot.sessionId] = snapshot.state
        }
        publish(.statusChanged(await status()))
    }

    /// Публикует `meetingsChanged`, если сменилась строка списка: статус записи продвинулся
    /// (`recording → stopping → finalized | failed`, дальше уже опубликованного) либо статус
    /// встречи отличается от опубликованного. Повтор того же изменения вторым путём (команда и
    /// снимок сессии) и запоздалый старый статус записи — молчат.
    func publishMeetingsChangedIfRowsChanged(
        recordingId: UUID?, recordingStatus: RecordingStatus?, meetingId: UUID?, meetingStatus: MeetingStatus?
    ) {
        var changed = false
        if let recordingId, let recordingStatus,
           publishedRecordingStatuses[recordingId].map({ Self.rank(recordingStatus) > Self.rank($0) }) ?? true {
            publishedRecordingStatuses[recordingId] = recordingStatus
            changed = true
        }
        if let meetingId, let meetingStatus, publishedMeetingStatuses[meetingId] != meetingStatus {
            publishedMeetingStatuses[meetingId] = meetingStatus
            changed = true
        }
        if changed { publish(.meetingsChanged) }
    }

    /// Строка списка по ответу команды записи (MEE-494, Б1/Б2): статус записи продвинулся —
    /// запоминается встреча записи, и `meetingsChanged` публикуется с парой «статус записи,
    /// статус встречи» (у встречи — тот же статус, что у сессии на входе в этот статус записи).
    /// Не продвинулся — снимок сессии успел раньше (в том же состоянии или дальше), и команда
    /// не публикует и не пишет в кэши ничего.
    func publishCommandRowChange(
        recordingId: UUID, recordingStatus: RecordingStatus, meetingId: UUID?, meetingStatus: MeetingStatus
    ) {
        let advanced = publishedRecordingStatuses[recordingId].map { Self.rank(recordingStatus) > Self.rank($0) }
        guard advanced ?? true else { return }
        if let meetingId { recordingMeetingIds[recordingId] = meetingId }
        publishMeetingsChangedIfRowsChanged(
            recordingId: recordingId, recordingStatus: recordingStatus,
            meetingId: meetingId, meetingStatus: meetingId.map { _ in meetingStatus }
        )
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
