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
            throw AppFacadeError.notAllowed(reason: "уже идёт запись другой сессии")
        }
        do {
            return try await sessionCoordinator.startRecording(meetingId: meetingId, now: clock())
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
        case .alreadyRecording(let sessionId):
            return .notAllowed(reason: "цель уже записывается другой сессией \(sessionId.uuidString)")
        case .nothingToRecord:
            return .notAllowed(reason: "нет звучащей цели для записи")
        case .sessionIsTerminal(let sessionId, let state):
            return .notAllowed(reason: "сессия \(sessionId.uuidString) в терминальном состоянии \(state.rawValue)")
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
    /// выдачи права. Оба `PromptTimedOut` — это истечение ожидания системного промпта, а не
    /// отказ права (право уже могло быть предоставлено позже пользователем), поэтому `nil`,
    /// как и у остальных восьми кейсов.
    func wrap(_ error: CaptureError) -> AppFacadeError {
        let description = String(describing: error)
        let name = description.split(separator: "(", maxSplits: 1).first.map(String.init) ?? description
        let permissionKind: PermissionKind?
        switch error {
        case .microphoneDenied:
            permissionKind = .microphone
        case .systemAudioDenied:
            permissionKind = .systemAudioRecording
        default:
            permissionKind = nil
        }
        return .underlying(AppErrorView(
            code: "capture.\(name)", message: description, recoverySuggestion: nil, permissionKind: permissionKind
        ))
    }
}
