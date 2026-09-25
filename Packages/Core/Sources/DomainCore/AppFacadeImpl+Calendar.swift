//  AppFacadeImpl — команды календаря и коннекторов (C-016 v10, группа О плана MEE-410;
//  К39-К40, MEE-441). `syncCalendars()`/`wrap(_:PermissionsError)` остаются в
//  `AppFacadeImpl.swift` (реализованы раньше, МЕЕ-437) — этот файл добавляет остальные шесть
//  методов «Команд календаря и прав» плюс `wrap(_:CalendarError)`, которого до этой задачи
//  не было нигде в `AppFacadeImpl*` (см. докстринг `ErrorDictionaryTests.swift`, «ЧЕТЫРЕ ИЗ
//  ВОСЬМИ — ВНЕ ДОСЯГАЕМОСТИ», CalendarError в их числе, — этой задачей достигаем).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  `setConnectorEnabled` — НЕ через `CalendarPort`. К39 (перечень MEE-401) называет его
//  «сквозной, 1:1 оборачивает... CalendarPort» вместе с тремя другими методами группы, но
//  у `CalendarPort` (13 методов, `CalendarPort.swift`) нет ни одного про включение/выключение
//  источника — шесть методов управляющей поверхности C-005 v6 (`beginAuth`/`completeAuth`/
//  `settingsSchema`/`configure`/`healthCheck`/`stop`) этого не несут, и state «включён» не
//  назван ни одним из тринадцати. Реальный `CalendarPort` (`CalendarPortImpl`,
//  `CalendarHub/CalendarPortImpl.swift`) сам читает `ConnectorRecord.isEnabled` из
//  `ConnectorRepository` НАПРЯМУЮ, минуя протокол порта, — `isEnabled` живёт в репозитории
//  ниже уровня `CalendarPort`, а не за одним из его методов. Тот же путь здесь, не
//  изобретённый: `connectors: ConnectorRepository` — новый параметр `AppFacadeImpl.init`
//  (см. `AppFacadeImpl.swift`), и `setConnectorEnabled` читает/пишет запись напрямую, тем же
//  приёмом, что `CalendarPortImpl.setSelectedCalendars`/`requireRecord`. Неизвестный `sourceId`
//  даёт `CalendarError.notConfigured(sourceId:)` — тот же case, что `requireRecord` бросает
//  там же по той же причине, не новый словарный код.
//
//  `connectorHealth` — четыре поля из шести даёт `CalendarPort.healthCheck(source:)`
//  (`status`/`message`/`lastSuccessfulSyncAt` → `status`/`message`/`lastSyncAt`) плюс
//  `sourceId`, данный входом. `isEnabled` берёт `ConnectorRepository` (реальное поле, не
//  изобретённое). `displayName`/`needsAuthorization` — ни у `CalendarPort`, ни у
//  `ConnectorRecord` нет ни одного поля под них (сверено чтением обоих целиком): дать
//  честный, не выдуманный ответ этой части типа нечем. `displayName` берёт единственную
//  доступную строку-идентификатор (`sourceId.rawValue`), `needsAuthorization` — `false`
//  безусловно. Оба — заведомо неполный, но не выдуманный ответ; настоящий источник для них
//  (например, отдельное поле `ConnectorRecord` или отдельный метод `CalendarPort`) — решение
//  контракта/архитектора, не эта задача (тот же класс разрыва, что `editSegmentText`/
//  `transcriptId(forSegmentId:)`, МЕЕ-437).

import Foundation

extension AppFacadeImpl {

    /// К39 (частично — см. докстринг файла для причины): читает текущую запись коннектора
    /// (`ConnectorRepository.all()`, фильтр по `sourceId.rawValue`) и записывает её же назад
    /// с изменённым `isEnabled` (`upsert`) — та же пара вызовов, что
    /// `CalendarPortImpl.setSelectedCalendars`, только поле другое. `CalendarPort` не вызван
    /// ни разу этим методом — см. докстринг файла.
    public func setConnectorEnabled(_ enabled: Bool, sourceId: CalendarSourceId) async throws {
        do {
            guard let record = try await connectorRecord(for: sourceId) else {
                throw CalendarError.notConfigured(sourceId: sourceId)
            }
            try await connectors.upsert(Self.withEnabled(record, isEnabled: enabled))
        } catch let error as CalendarError {
            throw wrap(error)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// К39: сквозная обёртка, `AuthChallenge` целиком, как отдала `CalendarPort.beginAuth` —
    /// ни `redirectScheme`, ни `authUrl` не разбираются и не подменяются (IR-120, C-016 v7).
    public func beginConnectorAuth(sourceId: CalendarSourceId) async throws -> AuthChallenge {
        do {
            return try await calendar.beginAuth(source: sourceId)
        } catch let error as CalendarError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// К39: сквозная обёртка над `CalendarPort.completeAuth`. Меняет состояние авторизации
    /// источника — инв. 15, тем же доводом, что `setConnectorEnabled` ниже: `.statusChanged`
    /// безусловно после успеха (симметрично `syncCalendars()`/К33).
    public func completeConnectorAuth(sourceId: CalendarSourceId, callbackUrl: URL) async throws -> String? {
        do {
            let result = try await calendar.completeAuth(source: sourceId, callbackUrl: callbackUrl)
            publish(.statusChanged(await status()))
            return result
        } catch let error as CalendarError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// К40: байты `CalendarPort.settingsSchema(source:)` возвращаются без разбора — фасад их
    /// не парсит (критерий проверяет отсутствие разбора: невалидный для схемы JSON не бросает
    /// здесь).
    public func connectorSettingsSchema(sourceId: CalendarSourceId) async throws -> Data {
        do {
            return try await calendar.settingsSchema(source: sourceId)
        } catch let error as CalendarError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// К40: сквозной вызов `CalendarPort.configure(source:settings:)` — байты настроек не
    /// разобраны фасадом, тем же доводом, что `connectorSettingsSchema`. Меняет сохранённую
    /// конфигурацию источника — `.statusChanged` безусловно после успеха, см.
    /// `completeConnectorAuth` выше.
    public func configureConnector(sourceId: CalendarSourceId, settings: Data) async throws {
        do {
            try await calendar.configure(source: sourceId, settings: settings)
            publish(.statusChanged(await status()))
        } catch let error as CalendarError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// К40: `ConnectorHealthView`, не сырой `ConnectorHealth` (IR-120, C-016 v7) — см.
    /// докстринг файла за разбором каждого поля.
    public func connectorHealth(sourceId: CalendarSourceId) async throws -> ConnectorHealthView {
        do {
            let health = try await calendar.healthCheck(source: sourceId)
            let record = try? await connectorRecord(for: sourceId)
            return ConnectorHealthView(
                sourceId: sourceId,
                displayName: sourceId.rawValue,
                isEnabled: record?.isEnabled ?? true,
                status: health.status,
                message: health.message,
                lastSyncAt: health.lastSuccessfulSyncAt,
                needsAuthorization: false
            )
        } catch let error as CalendarError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    private func connectorRecord(for sourceId: CalendarSourceId) async throws -> ConnectorRecord? {
        try await connectors.all().first(where: { $0.id == sourceId.rawValue })
    }

    private static func withEnabled(_ record: ConnectorRecord, isEnabled: Bool) -> ConnectorRecord {
        ConnectorRecord(
            id: record.id, type: record.type, pluginId: record.pluginId, settingsJson: record.settingsJson,
            keychainNamespace: record.keychainNamespace, selectedCalendarIds: record.selectedCalendarIds,
            isEnabled: isEnabled, lastSyncAt: record.lastSyncAt, cursor: record.cursor, lastError: record.lastError
        )
    }

    /// Имя кейса срезом до первой `(` — тот же приём, что `wrap(_:CaptureError)`
    /// (`AppFacadeImpl+Recording.swift`): шесть случаев `CalendarError`, явный `switch`
    /// избыточен там, где не нужен `permissionKind`.
    ///
    /// `permissionKind` — только `.authorizationRequired`, и только когда `sourceId` —
    /// `"eventkit"`: К30 (группа И, МЕЕ-437) называет ровно эту пару векторов («четыре
    /// вектора дают право; `calendar.authorizationRequired` при `.stdio` — `nil`») —
    /// `eventkit` — единственный встроенный коннектор, использующий системное право
    /// `.calendars` (`PermissionsPort.swift`); внешние (`stdio`, плагин-процесс) его не
    /// используют вовсе, поэтому отказ авторизации у них не про системное право.
    func wrap(_ error: CalendarError) -> AppFacadeError {
        let description = String(describing: error)
        let name = description.split(separator: "(", maxSplits: 1).first.map(String.init) ?? description
        var permissionKind: PermissionKind?
        if case .authorizationRequired(let sourceId) = error, sourceId.rawValue == "eventkit" {
            permissionKind = .calendars
        }
        return .underlying(AppErrorView(
            code: "calendar.\(name)", message: description, recoverySuggestion: nil, permissionKind: permissionKind
        ))
    }
}
