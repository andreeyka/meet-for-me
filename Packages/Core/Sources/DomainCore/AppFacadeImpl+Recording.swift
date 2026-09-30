//  AppFacadeImpl — команды записи (C-016 v10, группа В плана MEE-410; К10-К12). Разведено
//  из `AppFacadeImpl.swift` по объёму (`file_length`), не по смыслу — см. заголовок того
//  файла для обоснования конструкции (тонкая обёртка над `SessionCoordinator`).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

extension AppFacadeImpl {

    /// К11 (инв. 10): отсутствие права на запись бросает `.permissionRequired(kind)` с
    /// конкретным правом раньше любого обращения к `SessionCoordinator`. Контракт не
    /// называет, какое именно право проверяется, — микрофон единственный из шести
    /// `PermissionKind`, названный как «микрофонный канал записи» (`PermissionsPort.swift`);
    /// это узкое, явно раскрытое толкование, не изобретённое значение.
    ///
    /// К10 (инв. 9): уже идущая запись бросает `.notAllowed(reason:)` без единого
    /// дополнительного обращения к `SessionCoordinator` за пределами уже сделанного чтения
    /// `sessions()` — обе проверки идут до `sessionCoordinator.startRecording`, а не внутри
    /// него: `SessionError` не несёт кейса ни про право, ни про «активная сессия у ЭТОГО же
    /// вызова» (сама машина у одной и той же сессии отвечает тем же `recordingId`
    /// идемпотентно — `SessionMachineCommands.swift`, `alreadyRecording` — про ЧУЖУЮ
    /// сессию на той же цели).
    public func startRecording(meetingId: UUID?) async throws -> UUID {
        guard await permissionsPort.snapshot().status(of: .microphone) == .granted else {
            throw AppFacadeError.permissionRequired(.microphone)
        }
        let sessions = await sessionCoordinator.sessions()
        guard !sessions.contains(where: { $0.state == .recording }) else {
            throw AppFacadeError.notAllowed(reason: "Уже идёт другая запись — сначала остановите её")
        }
        do {
            let recordingId = try await sessionCoordinator.startRecording(meetingId: meetingId, now: clock())
            // К33 (МЕЕ-437, группа Л, инв. 15/16): `activeSession` в `AppStatus` меняется
            // ровно здесь — публикация после успешного старта, не до (отказавший старт не
            // менял состояния, которому стоило бы сообщать подписчикам).
            // Инв. 34 (а), IR-146: у записи появилась строка (`status == .recording`) — при любом
            // `meetingId`, до возврата и не позже `statusChanged`. Снимок сессии о том же входе в
            // `.recording` второго `meetingsChanged` не даст (MEE-492). Ответ, пришедший после
            // снимка `stopping`/`processing`/терминального, — ни события, ни записей в кэшах (MEE-494).
            publishCommandRowChange(
                recordingId: recordingId, recordingStatus: .recording, meetingId: meetingId, meetingStatus: .recording
            )
            publish(.statusChanged(await status()))
            return recordingId
        } catch let error as SessionError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// К12 (инв. 11): запись, которой нет, и уже остановленная запись — оба вектора
    /// проходят один и тот же путь `SessionCoordinator.stopRecording`, который отвечает
    /// `SessionError.noRecordingInProgress(recordingId:)` на оба (`SessionMachineCommands.swift`
    /// строки 122-131) — сведено к `.notFound`, один из двух видов, которые допускает
    /// критерий (контракт не называет, какой именно).
    public func stopRecording(recordingId: UUID) async throws {
        do {
            try await sessionCoordinator.stopRecording(recordingId: recordingId, now: clock())
            // К33: симметрично со стороной старта — публикация после успешной остановки.
            // Инв. 34 (б): `RecordingStatus` записи сменился на `stopping` — `meetingsChanged` не позже
            // `statusChanged` для того же изменения. Снимок сессии о том же входе в `stopping` —
            // пришёл он раньше или придёт позже — второго `meetingsChanged` не даст (MEE-492). Ответ
            // после снимка `processing` или терминального — не даст ничего (MEE-494).
            publishCommandRowChange(
                recordingId: recordingId, recordingStatus: .stopping,
                meetingId: recordingMeetingIds[recordingId], meetingStatus: .stopping
            )
            publish(.statusChanged(await status()))
        } catch let error as SessionError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// К47 (группа Х плана MEE-410, MEE-441; возврат РП, приёмка 12:00 UTC, находка 1):
    /// `SessionCoordinator.swift` называет `startRecording`/`stopRecording`/`skip` прямо —
    /// «Команды; их зовёт фасад C-016 §4» (§3.1) — тем же классом вызовов, что уже даёт
    /// `startRecording`/`stopRecording` выше. Первая редакция писала статус напрямую через
    /// `MeetingRepository.setStatus(.skipped, meetingId:)`, в обход машины сессий, — машина
    /// не узнавала о пропуске и продолжала бы взводить/записывать встречу. Симметрично
    /// `startRecording`/`stopRecording`: вызов `sessionCoordinator.skip`, отказ —
    /// `wrap(_:SessionError)`.
    ///
    /// Событие — инв. 15 (не К47: критерий его не называет). `.meetingsChanged` — пропуск
    /// меняет статус встречи, `.statusChanged` — то же поле участвует в `AppStatus.upcoming`,
    /// тем же доводом, что `syncCalendars()`/К33 выше.
    ///
    /// MEE-494 (Б3): из `recording`/`stopping`/`processing` машина `skip` не меняет ничего
    /// (C-018 §7, `SessionMachineCommands.swift`) и ответа об этом не даёт. Исход берётся из
    /// хранилища: машина пишет `setStatus` раньше возврата (C-018 инв. 18), и `meetingsChanged`
    /// идёт, только если встреча там правда `skipped`. Отвергнуто: чтение `sessions()` до или
    /// после команды — сессия успевает сменить состояние между чтением и командой.
    ///
    /// MEE-498: отказ чтения хранилища после успешной команды не глотается молча. Команда уже
    /// исполнена, и бросать нельзя: пропуск мог состояться, и отказ сказал бы обратное. Узнать,
    /// изменила ли команда строку, не из чего, — и `meetingsChanged` публикуется без условия и
    /// мимо кэша опубликованных статусов (инв. 15: изменившая данные команда обязана сообщить
    /// до возврата). Цена — возможное лишнее `meetingsChanged`: интерфейс перечитает список
    /// впустую; пропущенное событие оставило бы в списке устаревшую строку.
    public func skipMeeting(meetingId: UUID) async throws {
        do {
            try await sessionCoordinator.skip(meetingId: meetingId, now: clock())
            do {
                // MEE-492: снимок `skipped` той же встречи второго `meetingsChanged` не даст.
                if try await meetingRepository.meeting(id: meetingId)?.status == .skipped {
                    publishMeetingsChangedIfRowsChanged(
                        recordingId: nil, recordingStatus: nil, meetingId: meetingId, meetingStatus: .skipped
                    )
                }
            } catch {
                publish(.meetingsChanged)
            }
            publish(.statusChanged(await status()))
        } catch let error as SessionError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    func wrap(_ error: SessionError) -> AppFacadeError {
        switch error {
        case .noSuchMeeting(let meetingId):
            return .notFound(entity: "Meeting", id: meetingId.uuidString)
        case .noSuchSession(let sessionId):
            return .notFound(entity: "Session", id: sessionId.uuidString)
        case .noSuchPrompt(let promptId):
            return .notFound(entity: "Prompt", id: promptId.uuidString)
        case .noRecordingInProgress(let recordingId):
            return .notFound(entity: "Recording", id: recordingId.uuidString)
        // MEE-492 (решение РП по ревью #213): `reason` — текст для человека (§3.1), без UUID
        // сессии и `rawValue` состояния. Журнала в domain-core нет; диагностика — по `code`.
        case .alreadyRecording:
            return .notAllowed(reason: "Этот созвон уже записывается")
        case .nothingToRecord:
            return .notAllowed(reason: "Нечего записывать: ни одно приложение созвона сейчас не звучит")
        case .sessionIsTerminal:
            return .notAllowed(reason: "Эта запись уже завершена")
        case .capture(let captureError):
            return wrap(captureError)
        }
    }

    /// Одиннадцать случаев `CaptureError` — явный `switch` по имени кейса (как у соседних
    /// `wrap`) упирается в `cyclomatic_complexity` (порог 10). Кейсы без параметров и с
    /// параметрами `String(describing:)` печатает одинаково — именем кейса, за которым для
    /// непустых идёт `(...)`, — так что имя кейса безопасно взять срезом до первой `(`, не
    /// теряя произвольного нового кейса, который добавят позже без правки этой функции.
    ///
    /// Инв. 23, §3.1: `permissionKind` заполнен, только когда отказ вызван недостающим
    /// правом, — `.microphoneDenied` и `.systemAudioDenied` — иначе интерфейс теряет кнопку
    /// выдачи права. Оба `PromptTimedOut` под этот признак не подпадают буквально по тексту
    /// §3.1: причина отказа у них — не состояние права (оно то же, что было до отказа), а
    /// отсутствие ответа пользователя на системный запрос за отведённое время; признак,
    /// накрывший бы и их, обещал бы интерфейсу кнопку, которая ничего не меняет. §3.1 прямо
    /// называет, чьё поле обязано сказать это вместо `permissionKind`: «сказать это обязан
    /// `recoverySuggestion`». Текст поля не устойчив и не предмет теста на равенство (§3.1:
    /// «Тестам на равенство они не подлежат, и критерии на них не пишутся») — только его
    /// наличие для этих двух кейсов.
    func wrap(_ error: CaptureError) -> AppFacadeError {
        let code = UnderlyingErrorText.jobErrorCode("capture", error)
        var permissionKind: PermissionKind?
        // MEE-494: текст для человека по коду (§3.1), а не `String(describing:)`.
        var message = UnderlyingErrorText.message(code)
        var recoverySuggestion = UnderlyingErrorText.suggestion(code)
        switch error {
        case .microphoneDenied:
            permissionKind = .microphone
        case .systemAudioDenied:
            permissionKind = .systemAudioRecording
        case .systemAudioPromptTimedOut, .microphonePromptTimedOut:
            recoverySuggestion = "Начните запись заново и ответьте на системный запрос вовремя"
        default:
            break
        }
        if let permissionKind {
            // MEE-492 (ревью РП): отказ права — тот же человеческий текст и совет, что у
            // `facade.permissionRequired`, а не имя случая.
            message = AppFacadeError.permissionMissingText(permissionKind)
            recoverySuggestion = AppFacadeError.permissionSuggestion(permissionKind)
        }
        return .underlying(AppErrorView(
            code: code, message: message,
            recoverySuggestion: recoverySuggestion, permissionKind: permissionKind
        ))
    }
}
