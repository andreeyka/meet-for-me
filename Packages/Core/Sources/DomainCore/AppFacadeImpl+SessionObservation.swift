//  AppFacadeImpl — публикация `AppStatus` на смене состояния сессии (C-016 v10,
//  §«Поведение»; MEE-456).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ТЕКСТ КОНТРАКТА. «`AppStatus` пересчитывается и публикуется не реже чем при каждом
//  изменении: старт и стоп записи, смена состояния сессии, …». Источник смены —
//  `SessionCoordinator.changes()` (C-018 §3.1). Требования к порядку `.statusChanged`
//  относительно других событий C-016 не ставит; инв. 15 («до возврата управления») — про
//  команды, и для `startRecording`/`stopRecording`/`skipMeeting` уже исполнен в них самих.
//
//  ЧТО СЧИТАЕТСЯ СМЕНОЙ. `.session(snapshot)` с `state`, отличным от последнего известного
//  фасаду для этого `sessionId` (либо сессия видна впервые). Снимок с тем же `state` (новая
//  `estimate`/`target`/`updatedAt`) — не «смена состояния сессии», и в `AppStatus` из него
//  не видно ничего: `recordingId` у сессии появляется только вместе со входом в `.recording`
//  и дальше не меняется (C-018 §1.1). `.promptRaised`/`.promptWithdrawn` — не смена
//  состояния сессии, и спросов в `AppStatus` нет.
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
        publish(.statusChanged(await status()))
    }
}
