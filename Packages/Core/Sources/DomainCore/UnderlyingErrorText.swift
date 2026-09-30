//  UnderlyingErrorText — тексты для человека в `AppErrorView` ошибок снизу (`underlying`) и в
//  подробности `facade.jobFailed` (C-016 v13, §3.1 и инв. 37; MEE-494, продолжение MEE-492).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧТО ЗДЕСЬ И ПОЧЕМУ. §3.1: стабилен только `code`; `message` и `recoverySuggestion` — тексты для
//  человека, меняются без версии контракта, критериев на них нет. До MEE-494 фасад клал в
//  `message` `String(describing: error)` — пользователь читал `io(message: "…")`. Текст выбирается
//  по `code`, а не по значению ошибки: код уже построен правилом §3.1 для каждого источника, и один
//  словарь по коду покрывает и синхронные `wrap`, и строку отказа из очереди (`jobFailureDetail`).
//
//  Правило текста — то же, что в `AppFacadeError+Text.swift`: ни имени случая, ни скобок Swift, ни
//  идентификаторов. Код, которого нет в словаре (источник завёл новый случай, §3.1 п. 3), получает
//  общий текст своего источника по префиксу, а не имя случая.
//
//  `app.internalError` — отдельно (`internalErrorMessage`): §3.1 требует, чтобы `message` содержал
//  описание исходной ошибки, поэтому там человеческая фраза плюс подробность.

import Foundation

enum UnderlyingErrorText {

    struct Text {
        let message: String
        let suggestion: String?

        init(_ message: String, _ suggestion: String? = nil) {
            self.message = message
            self.suggestion = suggestion
        }
    }

    static func message(_ code: String) -> String { text(code).message }

    static func suggestion(_ code: String) -> String? { text(code).suggestion }

    /// Текст по коду §3.1; кода нет в словаре — общий текст источника по префиксу.
    static func text(_ code: String) -> Text {
        if let known = texts[code] { return known }
        if code.hasPrefix("engine.engineFailure.") { return Text("Сбой движка распознавания речи", retryLater) }
        let prefix = code.split(separator: ".", maxSplits: 1).first.map(String.init) ?? code
        return Text(prefixTexts[prefix] ?? "Не удалось выполнить действие")
    }

    /// `AppErrorView` ошибки снизу: код §3.1, текст по коду; `message` можно заменить текстом с
    /// подробностями значения (`nil` — текст словаря).
    static func view(
        code: String, message: String? = nil, suggestion: String? = nil, permissionKind: PermissionKind? = nil
    ) -> AppErrorView {
        let base = text(code)
        return AppErrorView(
            code: code, message: message ?? base.message,
            recoverySuggestion: suggestion ?? base.suggestion, permissionKind: permissionKind
        )
    }

    /// `app.internalError` (§3.1, строка «всё прочее»): «`message` обязан содержать описание
    /// исходной ошибки» — человеческая фраза плюс подробность.
    static func internalErrorMessage(_ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return "Внутренняя ошибка приложения. Подробности: \(detail)"
    }

    static let internalErrorSuggestion = "Повторите действие. Если ошибка повторится, перезапустите приложение."

    private static let retryLater = "Повторите позже."
    private static let checkNetwork = "Проверьте подключение к интернету и повторите."
    private static let checkDisk = "Проверьте свободное место на диске и повторите."
    private static let restartApp = "Перезапустите приложение."

    private static let prefixTexts: [String: String] = [
        "app": "Внутренняя ошибка приложения",
        "storage": "Ошибка хранилища данных",
        "calendar": "Ошибка календаря",
        "engine": "Ошибка службы распознавания речи",
        "models": "Ошибка каталога моделей",
        "attribution": "Не удалось опознать говорящих",
        "capture": "Ошибка записи звука",
        "permissions": "Ошибка системных разрешений",
        "jobs": "Ошибка очереди задач",
        "facade": "Не удалось выполнить действие"
    ]

    /// Словарь, а не `switch`: кодов больше, чем допускает `cyclomatic_complexity`.
    private static let texts: [String: Text] = storageAndCalendar
        .merging(engine) { first, _ in first }
        .merging(modelsAndAttribution) { first, _ in first }
        .merging(captureAndRest) { first, _ in first }

    private static let storageAndCalendar: [String: Text] = [
        "storage.notFound": Text("Нужные данные не найдены", "Возможно, это уже удалено — обновите список."),
        "storage.constraintViolation": Text("Данные противоречат уже сохранённым и не сохранены"),
        "storage.migrationFailed": Text("Не удалось обновить базу данных приложения", restartApp),
        "storage.fileMissing": Text("Нужный файл не найден на диске"),
        "storage.dataCorrupted": Text("Сохранённые данные повреждены и не читаются"),
        "storage.io": Text("Не удалось прочитать или записать данные на диск", checkDisk),
        "calendar.notConfigured": Text("Календарь не подключён", "Подключите календарь в настройках."),
        "calendar.authorizationRequired": Text(
            "Нужно заново войти в календарь", "Войдите в календарь заново в настройках."
        ),
        "calendar.transport": Text("Нет связи с календарём", checkNetwork),
        "calendar.protocolViolation": Text("Календарь прислал ответ, который приложение не понимает"),
        "calendar.timeout": Text("Календарь не ответил вовремя", retryLater),
        "calendar.cancelled": Text("Синхронизация календаря отменена")
    ]

    private static let engine: [String: Text] = [
        "engine.serviceUnavailable": Text("Служба распознавания речи недоступна", retryLater),
        "engine.serviceCrashed": Text("Служба распознавания речи аварийно завершилась", retryLater),
        "engine.protocolVersionMismatch": Text(
            "Версии приложения и службы распознавания речи не совпадают", "Переустановите приложение."
        ),
        "engine.messageTooLarge": Text("Ответ службы распознавания речи слишком велик"),
        "engine.invalidRequest": Text("Служба распознавания речи отклонила запрос"),
        "engine.modelsNotReady": Text(
            "Модели для распознавания не готовы", "Загрузите недостающие модели в настройках."
        ),
        "engine.recordingNotReady": Text("Запись ещё не готова к распознаванию"),
        "engine.timedOut": Text("Служба распознавания речи не ответила вовремя", retryLater),
        "engine.cancelled": Text("Распознавание отменено"),
        "engine.engineFailure.modelMissing": Text("Не найден файл модели", "Загрузите модель заново в настройках."),
        "engine.engineFailure.modelIncompatible": Text("Модель не подходит к движку распознавания"),
        "engine.engineFailure.audioUnreadable": Text("Не удалось прочитать звук записи"),
        "engine.engineFailure.unsupportedLanguage": Text("Язык записи не поддерживается"),
        "engine.engineFailure.unsupportedRequest": Text("Движок распознавания не поддерживает такой запрос"),
        "engine.engineFailure.outOfMemory": Text(
            "Не хватило памяти для распознавания", "Закройте другие программы и повторите."
        ),
        "engine.engineFailure.cancelled": Text("Распознавание отменено"),
        "engine.engineFailure.invalidResult": Text("Движок распознавания вернул негодный результат"),
        "engine.engineFailure.runtimeFailure": Text("Сбой движка распознавания речи", retryLater)
    ]

    private static let modelsAndAttribution: [String: Text] = [
        "models.manifestInvalid": Text("Каталог моделей повреждён"),
        "models.manifestUnreachable": Text("Каталог моделей недоступен", checkNetwork),
        "models.unknownModel": Text("Такой модели нет в каталоге"),
        "models.unknownProfile": Text("Профиль распознавания не найден"),
        "models.notDownloaded": Text("Модель не загружена", "Загрузите модель в настройках."),
        "models.checksumMismatch": Text("Загруженный файл модели повреждён", "Загрузите модель заново."),
        "models.downloadFailed": Text("Не удалось загрузить модель", checkNetwork),
        "models.insufficientDiskSpace": Text("Недостаточно места на диске", "Освободите место на диске и повторите."),
        "models.unsupportedChip": Text("Модель не работает на процессоре этого Mac"),
        "models.insufficientRAM": Text("Модели не хватает оперативной памяти этого Mac"),
        "models.modelInUseByProfile": Text(
            "Модель нужна профилям распознавания", "Сначала уберите её из этих профилей."
        ),
        "models.modelInUse": Text("Модель сейчас используется", "Дождитесь окончания обработки и повторите."),
        "models.userProfilesUnreadable": Text("Не удалось прочитать ваши профили распознавания"),
        "models.builtInProfileImmutable": Text("Встроенный профиль распознавания изменить нельзя"),
        "models.cancelled": Text("Загрузка модели отменена"),
        "attribution.unknownTranscript": Text("Транскрипт не найден"),
        "attribution.unknownCluster": Text("Говорящий не найден в транскрипте"),
        "attribution.unknownPerson": Text("Человек не найден"),
        "attribution.embeddingModelMismatch": Text("Голосовые профили созданы другой моделью и не подходят"),
        "attribution.segmentIdsMismatch": Text("Транскрипт изменился во время опознания говорящих", retryLater),
        "attribution.voiceProfilesDisabled": Text("Голосовые профили выключены", "Включите их в настройках.")
    ]

    /// У `PromptTimedOut` и у отказа права совет задаёт `wrap(_:CaptureError)` (MEE-492); здесь —
    /// советы тех случаев, где пользователю есть что сделать самому (MEE-498).
    private static let captureAndRest: [String: Text] = [
        "capture.alreadyRunning": Text("Запись звука уже идёт"),
        "capture.notRunning": Text("Запись звука не идёт"),
        "capture.nothingToCapture": Text("Нечего записывать: не выбран ни один источник звука"),
        "capture.systemAudioPromptTimedOut": Text("Не дождались ответа на запрос доступа к системному звуку"),
        "capture.microphonePromptTimedOut": Text("Не дождались ответа на запрос доступа к микрофону"),
        "capture.inputDeviceUnavailable": Text(
            "Микрофон недоступен", "Проверьте, что микрофон подключён, или выберите другой в настройках."
        ),
        "capture.directoryUnusable": Text("Не удалось сохранить запись в папку приложения", checkDisk),
        "capture.systemUnavailable": Text("Системный звук сейчас недоступен"),
        "capture.recoveryFailed": Text("Не удалось восстановить прерванную запись"),
        "permissions.loginItemRegistrationFailed": Text("Не удалось включить запуск при входе в систему"),
        "permissions.settingsPaneUnavailable": Text(
            "Не удалось открыть нужный раздел Системных настроек", "Откройте Системные настройки вручную."
        ),
        "jobs.unknownJob": Text("Задача не найдена", "Возможно, она уже удалена — обновите список."),
        "jobs.invalidPriority": Text("Недопустимый приоритет задачи"),
        "jobs.handlerAlreadyRegistered": Text("Обработчик задач уже зарегистрирован")
    ]
}

// MARK: - Строка отказа задачи и подробность `facade.jobFailed`

extension UnderlyingErrorText {

    /// Код §3.1 `<префикс>.<имя case>` без значений: имя случая — срезом `String(describing:)`
    /// до первой `(`. Одно выражение на оба пути (MEE-506): строка отказа задачи
    /// (`JobOutcome.error`, MEE-498 — ни описания значения Swift, ни идентификаторов в очередь
    /// не пишется) и `code` синхронных `wrap` фасада (`CalendarError`, `CaptureError`, `ruleView`).
    static func jobErrorCode(_ prefix: String, _ error: Error) -> String {
        let description = String(describing: error)
        let name = description.split(separator: "(", maxSplits: 1).first.map(String.init) ?? description
        return "\(prefix).\(name)"
    }

    /// Строка отказа задачи для ошибки вне словаря §3.1 — «всё прочее», `app.internalError`.
    static let internalErrorCode = "app.internalError"

    /// Нагрузка задачи не того вида, что обработчик: обработчик зарегистрирован не на свой
    /// тип. Ошибка сборки приложения, а не данных пользователя.
    static let wrongPayloadText = "Внутренняя ошибка приложения: задача передана не своему обработчику"

    /// Подробность отказа задачи для `AppErrorView.message` (`nil` — показывать нечего). Строку
    /// `error` события очереди (C-013) пишет обработчик: код §3.1 (`storage.io`,
    /// `app.internalError`), текст для человека либо свободный текст движка (`"oom"`); строки
    /// прежних изданий и `"interrupted"` очереди — описание значения Swift (`io(message: "…")`,
    /// `serviceCrashed`, `timedOut(30)`). Сама строка в `AppFacadeError.jobFailed` остаётся
    /// дословной (инв. 31) — переводится только текст показа:
    ///  • код §3.1 — текст по коду; код незнакомого источника — строка как есть (свободный
    ///    текст движка с точкой, `"cuda.oom"`);
    ///  • значение Swift, возможно с меткой впереди (`save: io(…)`), — текст по коду источника
    ///    (хранилище, атрибуция, движок, фасад); незнакомое имя случая (`lowerCamelCase` или со
    ///    скобками) — без подробности; незнакомое слово строчными (`"oom"`) — как есть (MEE-498);
    ///  • строка с описанием значения Swift внутри (`метка(поле: …)`) — без подробности;
    ///  • прочее — текст обработчика или движка как есть.
    static func jobFailureDetail(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: #"^[a-z]+(\.[A-Za-z0-9_]+)+$"#, options: .regularExpression) != nil {
            return codeText(trimmed).map(lowercasedFirst) ?? trimmed
        }
        let value = trimmed.replacingOccurrences(
            of: #"^[a-z]+: (?=[a-z][A-Za-z0-9]*(\(|$))"#, with: "", options: .regularExpression
        )
        if let range = value.range(of: #"^[a-z][A-Za-z0-9]*(?=(\(.*\))?$)"#, options: .regularExpression) {
            let name = String(value[range])
            if let known = caseNameText(name) { return lowercasedFirst(known) }
            let isBareWord = name == value && name.range(of: "[A-Z]", options: .regularExpression) == nil
            return isBareWord ? value : nil
        }
        if trimmed.range(of: #"[A-Za-z]\([a-zA-Z]+: "#, options: .regularExpression) != nil {
            return nil
        }
        return trimmed
    }

    /// Текст кода §3.1; `nil` — источник кода не из словаря (строка не код, а свободный текст).
    private static func codeText(_ code: String) -> String? {
        if let known = texts[code] { return known.message }
        let parts = code.split(separator: ".", maxSplits: 1).map(String.init)
        if parts[0] == "facade", parts.count == 2, let facadeText = facadeCaseTexts[parts[1]] { return facadeText }
        guard prefixTexts[parts[0]] != nil else { return nil }
        return text(code).message
    }

    /// Имя случая из строки очереди — к коду §3.1 по источникам, которые пишут обработчики
    /// задач (`TranscribeJobHandler`, `AttributeJobHandler`), в порядке их приоритета.
    private static func caseNameText(_ name: String) -> String? {
        if name == "interrupted" { return "Задача прервана: приложение закрылось во время её выполнения" }
        if let facadeText = facadeCaseTexts[name] { return facadeText }
        for prefix in ["engine", "storage", "attribution", "engine.engineFailure"] {
            if let known = texts["\(prefix).\(name)"] { return known.message }
        }
        return nil
    }

    /// Случаи `AppFacadeError`, которые `AttributeJobHandler` кладёт в очередь: кодом
    /// `facade.<case>` (MEE-498) либо, в строках прежних изданий, описанием значения.
    private static let facadeCaseTexts: [String: String] = [
        "settingsUnreadable": "Не удалось прочитать настройку",
        "profileNotReady": "Модели профиля распознавания не загружены",
        "permissionRequired": "Нет нужного системного разрешения",
        "notFound": "Нужные данные не найдены"
    ]

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
