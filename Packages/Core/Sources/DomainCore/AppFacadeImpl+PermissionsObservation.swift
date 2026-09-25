//  AppFacadeImpl — подписка фасада на PermissionsPort.changes() (C-016 v10, группа Л плана
//  MEE-410, К33). Возврат РП (МЕЕ-437, приёмка 10:15 UTC, находка 4): «Поведение» требует
//  `.statusChanged` там, где по контракту меняется статус — смена права меняет
//  `permissionsReady`, часть `AppStatus`, независимо от того, вызвал ли её саму какой-то
//  метод фасада (право может смениться в системных настройках, мимо любой команды).
//
//  Модуль: domain-core · Владелец: DEV-1 (в помощь MEE-420) · Слой: домен
//
//  Смена состояния сессии, события очереди задач, изменение состава захвата — те же
//  «Поведение», но группы Р/Н, вне зоны этой задачи («группы М–Х не трогать») — их
//  собственная публикация `.statusChanged` остаётся будущей работой той группы.

import Foundation

extension AppFacadeImpl {

    /// Цикл на весь срок жизни актора — подписка регистрируется в `init` (см. докстринг там),
    /// это тело просто читает уже гарантированно не потерянные снимки. Первым шагом снимает
    /// СВОЮ базовую готовность через `permissionsPort.snapshot()` (не через сам поток
    /// `changes()` — независимый вызов, не потребляет ни одного элемента буфера) — без этого
    /// самое первое пришедшее в `changes()` событие сравнивать было бы не с чем, и
    /// `.statusChanged` на нём никогда не ушёл бы, даже если право действительно сменилось
    /// относительно состояния на момент запуска.
    func observePermissionsChanges(_ stream: AsyncStream<PermissionSnapshot>) async {
        if lastKnownPermissionsReadiness == nil {
            let initialSnapshot = await permissionsPort.snapshot()
            let initialSettings = (try? await settings()) ?? AppSettings.slice1Defaults
            lastKnownPermissionsReadiness = permissionsReady(snapshot: initialSnapshot, settings: initialSettings)
        }
        for await snapshot in stream {
            let currentSettings = (try? await settings()) ?? AppSettings.slice1Defaults
            let newReadiness = permissionsReady(snapshot: snapshot, settings: currentSettings)
            publish(.permissionsChanged(snapshot))
            if let previous = lastKnownPermissionsReadiness, previous != newReadiness {
                publish(.statusChanged(await status()))
            }
            lastKnownPermissionsReadiness = newReadiness
        }
    }
}
