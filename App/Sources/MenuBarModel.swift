//  MenuBarModel — чистая логика меню-бара (MEE-473): что показывать при каком `AppStatus` и
//  какая команда фасада уходит по нажатию. Без SwiftUI и без `AppFacade`-вызовов — только
//  значения, чтобы логику можно было проверить чтением (постановка MEE-473, «Готовность»:
//  тестового таргета у App нет, `DomainTestKit` в релизный App не тянется, MEE-430 §3).
//
//  Исполнение команд и подписка на `AppFacade.events()` — `MenuBarController.swift`;
//  отрисовка — `StatusMenu.swift`. Оба только переводят данные этого файла в вызовы и виды.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

// MARK: - Команды

/// Всё, что меню может попросить у фасада. Одно нажатие — одна команда C-016 §4
/// (`requestRecordingPermissions` — два вызова `requestPermission(_:)` подряд, п. 4 постановки).
enum MenuCommand: Equatable, Sendable {
    case startRecording
    case stopRecording(recordingId: UUID)
    case requestRecordingPermissions
    case openPermissionSettings(PermissionKind)
}

/// Исход одной команды — то, что контроллер возвращает модели после `await`.
enum MenuCommandResult: Equatable, Sendable {
    case succeeded
    case failed(AppErrorView)
    case permissionsRequested([PermissionOutcomeLine])
}

struct PermissionOutcomeLine: Equatable, Sendable {
    let kind: PermissionKind
    let outcome: PermissionRequestOutcome
}

// MARK: - Состояние

struct MenuBarState: Equatable, Sendable {

    /// Права, которые запрашивает пункт «Разрешить запись…» (п. 4 постановки) — в этом порядке.
    static let recordingPermissionKinds: [PermissionKind] = [.microphone, .systemAudioRecording]

    /// Последний снимок фасада. `nil` — ещё ни одного (`status()` не отработал).
    private(set) var status: AppStatus?
    /// Доля по `AppEvent.jobProgressed`, ключ — `jobId`. Накрывает `RunningJobView.fraction`.
    private(set) var jobFractions: [UUID: Double] = [:]
    /// Последний отказ — синхронный (бросок команды) или асинхронный (`AppEvent.failure`,
    /// инв. 31). Одна строка, без модальных окон (п. 5 постановки).
    private(set) var lastError: AppErrorView?
    /// Исходы последнего «Разрешить запись…».
    private(set) var permissionOutcomes: [PermissionOutcomeLine] = []
    /// Команда, ответ на которую ещё не пришёл. Пока она есть, все команды неактивны.
    private(set) var inFlight: MenuCommand?

    // MARK: Входы

    mutating func apply(status newStatus: AppStatus) {
        status = newStatus
        // Доли держим только для задач, которые снимок ещё называет идущими.
        let running = Set(newStatus.runningJobs.map(\.jobId))
        jobFractions = jobFractions.filter { running.contains($0.key) }
        if newStatus.permissionsReady == .ready {
            permissionOutcomes = []
        }
    }

    mutating func apply(event: AppEvent) {
        switch event {
        case .statusChanged(let newStatus):
            apply(status: newStatus)
        case .jobProgressed(let jobId, _, let fraction):
            jobFractions[jobId] = min(max(fraction, 0), 1)
        case .failure(let view):
            lastError = view
        case .meetingsChanged, .transcriptChanged, .permissionsChanged, .modelsChanged, .settingsChanged:
            return
        }
    }

    /// `false` — команда уже идёт, второе нажатие не шлёт вторую (инвариант постановки).
    mutating func begin(_ command: MenuCommand) -> Bool {
        guard inFlight == nil else { return false }
        inFlight = command
        return true
    }

    mutating func finish(_ command: MenuCommand, result: MenuCommandResult) {
        guard inFlight == command else { return }
        inFlight = nil
        switch result {
        case .succeeded:
            if case .startRecording = command { lastError = nil }
        case .failed(let view):
            lastError = view
        case .permissionsRequested(let lines):
            permissionOutcomes = lines
        }
    }

    mutating func dismissError() {
        lastError = nil
    }
}

// MARK: - Отказы → AppErrorView

extension MenuBarState {

    /// Бросок команды фасада → `AppErrorView` для строки меню (п. 5 постановки). `underlying`
    /// уже несёт вид. Для остальных случаев `AppFacadeError` фасад публичного перевода в
    /// `AppErrorView` не даёт (`AppFacadeImpl.errorView(for:)` — internal), поэтому код
    /// строится по C-016 §3.1 (`facade.<имя случая>`), а `message` — текст для человека.
    static func errorView(for error: Error) -> AppErrorView {
        guard let facadeError = error as? AppFacadeError else {
            return AppErrorView(
                code: "app.internalError", message: String(describing: error),
                recoverySuggestion: nil, permissionKind: nil
            )
        }
        switch facadeError {
        case .underlying(let view):
            return view
        case .permissionRequired(let kind):
            return AppErrorView(
                code: "facade.permissionRequired",
                message: "Нет права: \(permissionTitle(kind))",
                recoverySuggestion: "Разрешите доступ в Системных настройках",
                permissionKind: kind
            )
        case .notAllowed(let reason):
            return AppErrorView(
                code: "facade.notAllowed", message: reason, recoverySuggestion: nil, permissionKind: nil
            )
        case .notFound(let entity, let id):
            return AppErrorView(
                code: "facade.notFound", message: "\(entity) \(id) не найден",
                recoverySuggestion: nil, permissionKind: nil
            )
        case .profileNotReady, .settingsUnreadable, .jobFailed:
            return AppErrorView(
                code: "facade.\(caseName(facadeError))", message: String(describing: facadeError),
                recoverySuggestion: nil, permissionKind: nil
            )
        }
    }

    private static func caseName(_ error: AppFacadeError) -> String {
        let description = String(describing: error)
        return description.split(separator: "(", maxSplits: 1).first.map(String.init) ?? description
    }

    static func permissionTitle(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: return "микрофон"
        case .systemAudioRecording: return "запись системного звука"
        case .screenRecording: return "запись экрана и звука"
        case .calendars: return "календари"
        case .notifications: return "уведомления"
        case .accessibility: return "универсальный доступ"
        }
    }
}
