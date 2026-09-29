//  AppFacadeImpl — асинхронный путь ошибки (`AppEvent.failure`) и строки словаря §3.1,
//  которых не было: `engine.*` и `facade.*` (C-016 v10, MEE-25; К27, К29 перечня MEE-401;
//  задача MEE-450).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧТО ЗДЕСЬ НАЗВАНО КОНТРАКТОМ ДОСЛОВНО.
//   • §«Поведение»: «асинхронно — как `AppEvent.failure` для того, что произошло само
//     (упала синхронизация, упала задача, отвалился движок)».
//   • Инв. 24: синхронный и асинхронный пути дают на одном и том же событии один и тот же
//     `code`. Поэтому асинхронный путь не заводит своего словаря: `errorView(for:)` сводит
//     ошибку теми же `wrap(_:)`, что бросают синхронные команды, и только затем строит
//     `AppErrorView` — расходиться двум путям не в чем по построению.
//   • §3.1: `AppFacadeError` — источник с префиксом `facade.`; `underlying(AppErrorView)`
//     «кода не образует»: вложенный `AppErrorView` проходит наружу без изменений. Журнал
//     изданий (v2, п. 2) называет путь, которым `AppFacadeError` доезжает до словаря, прямо:
//     «путь `AppEvent.failure`» — синхронно она бросается как есть.
//   • §3.1, строка `TranscriptionServiceError`: префикс `engine.`, а `engineFailure(code:
//     message:)` разворачивается на три сегмента — `engine.engineFailure.<code>`.
//
//  ЧЕГО КОНТРАКТ НЕ НАЗЫВАЕТ, И ЧТО ПОЭТОМУ ЗДЕСЬ НЕ СДЕЛАНО. Три примера из §«Поведение» —
//  примеры, а не перечень мест: ни издание v10, ни перечень MEE-401 не говорят, какой
//  компонент наблюдает «упавшую синхронизацию/задачу/движок» и передаёт её фасаду, по
//  какому входу (порт, поток, callback) и при каких условиях. В том, что фасад держит
//  сегодня, такого входа нет: `CalendarPort` отдаёт наружу только `changes()` (встречи, не
//  результаты фоновой синхронизации), `JobQueue` передан фасаду только командам группы Н
//  (MEE-420; поток `JobQueue.events()` фасад не наблюдает — IR-143, MEE-457), к
//  `TranscriptionServicePort` фасад не обращается ни одним методом §4. Поэтому
//  `publishFailure(_:)` — готовый и проверенный механизм без вызывающего в продакшене;
//  места вызова ждут ответа архитектора (вопрос в отчёте MEE-450), а не выбраны здесь.

import Foundation

extension AppFacadeImpl {

    // MARK: - Асинхронный путь (§«Поведение», инв. 24)

    /// Публикует `AppEvent.failure` с `AppErrorView`, построенным тем же словарём, что
    /// синхронный путь (инв. 24). Не бросает: асинхронному отказу некому его вернуть.
    func publishFailure(_ error: Error) async {
        publish(.failure(await errorView(for: error)))
    }

    /// Единая точка свода любой ошибки к `AppErrorView` по §3.1. Каждый источник проходит
    /// ТОТ ЖЕ `wrap(_:)`, которым его заворачивает синхронная команда, поэтому код на двух
    /// путях совпадает по построению (инв. 24). Тип без префикса — `app.internalError`
    /// (инв. 19, тотальность). `default:` здесь законен: `Error` — не перечисление, и
    /// «прочее» по §3.1 и есть отдельная строка словаря.
    func errorView(for error: Error) async -> AppErrorView {
        let wrapped: AppFacadeError
        switch error {
        case let facadeError as AppFacadeError: wrapped = facadeError
        case let storageError as StorageError: wrapped = wrap(storageError)
        case let calendarError as CalendarError: wrapped = await wrap(calendarError)
        case let captureError as CaptureError: wrapped = wrap(captureError)
        case let sessionError as SessionError: wrapped = wrap(sessionError)
        case let attributionError as AttributionError: wrapped = wrap(attributionError)
        case let permissionsError as PermissionsError: wrapped = wrap(permissionsError)
        case let serviceError as TranscriptionServiceError: wrapped = wrap(serviceError)
        default: wrapped = wrapCatalogOrQueue(error)
        }
        return Self.errorView(for: wrapped)
    }

    /// Источники групп М/Н (MEE-420) — тот же `wrap`, что у их синхронных команд; прочее —
    /// `app.internalError`. Вынесено из `errorView(for:)` по сложности (SwiftLint), не по смыслу.
    private func wrapCatalogOrQueue(_ error: Error) -> AppFacadeError {
        switch error {
        case let catalogError as ModelCatalogError: return wrap(catalogError)
        case let queueError as JobQueueError: return wrap(queueError)
        default: return wrapUnexpected(error)
        }
    }

    // MARK: - `facade.*` (§3.1, строка `AppFacadeError`)

    /// `facade.<имя case>`; `underlying` кода не образует — вложенный `AppErrorView` проходит
    /// без изменений (§3.1, «Три строки…», п. 2). `permissionKind` (инв. 23, §3.1): у
    /// `facade.permissionRequired` — «тем `PermissionKind`, который несёт сам случай», у
    /// прочих четырёх — `nil`. `switch` без `default:` — новый случай `AppFacadeError`
    /// обязан стать ошибкой компиляции, а не молча уехать в чужой код.
    static func errorView(for error: AppFacadeError) -> AppErrorView {
        let name: String
        var permissionKind: PermissionKind?
        switch error {
        case .underlying(let view):
            return view
        case .notFound: name = "notFound"
        case .notAllowed: name = "notAllowed"
        case .permissionRequired(let kind):
            name = "permissionRequired"
            permissionKind = kind
        case .profileNotReady: name = "profileNotReady"
        case .settingsUnreadable: name = "settingsUnreadable"
        }
        return AppErrorView(
            code: "facade.\(name)", message: String(describing: error),
            recoverySuggestion: nil, permissionKind: permissionKind
        )
    }

    // MARK: - `engine.*` (§3.1, строки `TranscriptionServiceError` и `EngineError`)

    /// Восемь случаев — `engine.<имя case>`; `engineFailure(code:message:)` — три сегмента,
    /// `engine.engineFailure.<code>`, где `<code>` — «тот самый код из C-012, то есть имя
    /// случая `EngineError`», подставленный как есть. Ни один случай не вызван состоянием
    /// системного права — `permissionKind` всюду `nil` (инв. 23).
    ///
    /// Вызывающего синхронного метода у этого `wrap` нет, и это по контракту, а не пропуск:
    /// ни один метод §4 не обращается к `TranscriptionServicePort` (`retranscribe` ставит
    /// задачу в очередь, группа Н), а §«Поведение» называет отказ движка асинхронным путём
    /// («отвалился движок»). Сюда его приводит `errorView(for:)`.
    func wrap(_ error: TranscriptionServiceError) -> AppFacadeError {
        let code: String
        switch error {
        case .serviceUnavailable: code = "engine.serviceUnavailable"
        case .serviceCrashed: code = "engine.serviceCrashed"
        case .protocolVersionMismatch: code = "engine.protocolVersionMismatch"
        case .messageTooLarge: code = "engine.messageTooLarge"
        case .invalidRequest: code = "engine.invalidRequest"
        case .modelsNotReady: code = "engine.modelsNotReady"
        case .timedOut: code = "engine.timedOut"
        case .cancelled: code = "engine.cancelled"
        case .engineFailure(let engineCode, _): code = "engine.engineFailure.\(engineCode)"
        }
        return .underlying(AppErrorView(
            code: code, message: String(describing: error), recoverySuggestion: nil, permissionKind: nil
        ))
    }
}
