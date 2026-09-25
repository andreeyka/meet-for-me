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
    /// это тело просто читает уже гарантированно не потерянные снимки.
    ///
    /// НАМЕРЕННО НЕТ отдельного шага «снять базовую готовность до цикла» — ранняя редакция
    /// делала это через `permissionsPort.snapshot()`/`settings()` СРАЗУ при запуске, для
    /// КАЖДОГО построенного `AppFacadeImpl`, включая те тысячи тестовых фикстур по всему
    /// таргету, что вообще не касаются прав. Это гонка с любым тестом, что сам считает
    /// обращения к `SettingsRepository`/`PermissionsPort` (общий `PortCallLog` в
    /// `InMemoryRepositories`) — находка CI после первого варианта этого файла: он добавлял
    /// седьмую строку в журнал `SettingsTests.test_k22_...`, читавший ровно шесть. Тело ниже
    /// не трогает ни один порт, пока `changes()` действительно не пришлёт снимок, — молчаливый
    /// подписчик без единого вызова не даёт побочных эффектов. Цена: самое первое пришедшее
    /// событие только заводит базу (`lastKnownPermissionsReadiness == nil`), `.statusChanged`
    /// на нём не публикуется — сравнивать было бы не с чем.
    func observePermissionsChanges(_ stream: AsyncStream<PermissionSnapshot>) async {
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
