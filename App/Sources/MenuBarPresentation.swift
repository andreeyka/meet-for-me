//  MenuBarPresentation — что меню рисует из `MenuBarState` (MEE-473). Чистая функция от
//  состояния и текущего времени: `StatusMenu` только перебирает строки и кнопки этого значения.
//  Разведено из `MenuBarModel.swift` по смыслу: там — переходы состояния, здесь — вид.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

struct MenuAction: Equatable, Sendable, Identifiable {
    let title: String
    let command: MenuCommand
    let isEnabled: Bool

    var id: String { title }
}

/// Строка меню со стабильным id (MEE-478 п. 3): `ForEach` не берёт id из текста — две задачи
/// одного типа с одинаковой долей дали бы одну и ту же строку.
struct MenuLine: Equatable, Sendable, Identifiable {
    let id: String
    let text: String
}

struct MenuBarPresentation: Equatable, Sendable {
    /// Строки блока активной сессии (название, время, уровни, предупреждение).
    var sessionLines: [MenuLine] = []
    /// Главная кнопка: «Начать запись» или «Остановить запись». `nil` — статуса ещё нет.
    var recordingAction: MenuAction?
    /// «Разрешить запись…» (`.notReady`) или «Проверить права на запись…»
    /// (`.unknownUntilFirstUse`) — пока `permissionsReady != .ready`.
    var permissionAction: MenuAction?
    /// Исходы последнего запроса прав (или пояснение к `.unknownUntilFirstUse`) и кнопки
    /// «Открыть настройки» к отказанным.
    var permissionLines: [MenuLine] = []
    var settingsActions: [MenuAction] = []
    /// Очередь: идущие задачи с долей и счётчики.
    var jobLines: [MenuLine] = []
    /// Последний отказ одной строкой (п. 5 постановки).
    var errorLine: String?
    /// Строка-заглушка, пока нет ни одного снимка.
    var placeholder: String?

    init(state: MenuBarState, now: Date) {
        guard let status = state.status else {
            placeholder = "Загрузка статуса…"
            return
        }
        let busy = state.inFlight != nil
        if let session = status.activeSession {
            sessionLines = Self.sessionLines(session, now: now)
            recordingAction = MenuAction(
                title: "Остановить запись",
                command: .stopRecording(recordingId: session.recordingId), isEnabled: !busy
            )
        } else {
            sessionLines = [MenuLine(id: "session.none", text: "Нет активной записи")]
            recordingAction = MenuAction(title: "Начать запись", command: .startRecording, isEnabled: !busy)
        }
        if let title = Self.permissionActionTitle(status.permissionsReady) {
            permissionAction = MenuAction(title: title, command: .requestRecordingPermissions, isEnabled: !busy)
        }
        permissionLines = state.permissionOutcomes.map(Self.permissionLine)
        if permissionLines.isEmpty, status.permissionsReady == .unknownUntilFirstUse {
            permissionLines = [MenuLine(
                id: "permissions.unknownUntilFirstUse",
                text: "Системный звук: macOS спросит разрешение при первой записи"
            )]
        }
        var settingsKinds = state.permissionOutcomes
            .filter { $0.outcome == .denied || $0.outcome == .cannotPrompt }
            .map(\.kind)
        if let kind = state.lastError?.permissionKind, !settingsKinds.contains(kind) {
            settingsKinds.append(kind)
        }
        settingsActions = settingsKinds.map {
            MenuAction(
                title: "Открыть настройки: \(MenuBarState.permissionTitle($0))",
                command: .openPermissionSettings($0), isEnabled: !busy
            )
        }
        jobLines = Self.jobLines(status, fractions: state.jobFractions)
        errorLine = state.lastError.map(Self.errorLine)
    }

    /// MEE-478 п. 4: `.unknownUntilFirstUse` — не «запрещено»: системный звук у macOS до первой
    /// записи неизвестен (C-007), и зовущая подпись «Разрешить» вводила бы в заблуждение.
    static func permissionActionTitle(_ readiness: PermissionsReadiness) -> String? {
        switch readiness {
        case .ready: return nil
        case .notReady: return "Разрешить запись…"
        case .unknownUntilFirstUse: return "Проверить права на запись…"
        }
    }

    // MARK: Строки

    static func sessionLines(_ session: ActiveSessionView, now: Date) -> [MenuLine] {
        let recordingId = session.recordingId.uuidString
        var lines = [MenuLine(
            id: "session.\(recordingId).title",
            text: "● \(session.title) — \(elapsed(from: session.startedAt, to: now))"
        )]
        var levels: [String] = []
        if let mic = session.micLevel { levels.append("микрофон \(meter(mic))") }
        if let system = session.systemLevel { levels.append("система \(meter(system))") }
        if !levels.isEmpty {
            lines.append(MenuLine(id: "session.\(recordingId).levels", text: levels.joined(separator: "  ")))
        }
        if session.containsUnrequested {
            lines.append(MenuLine(
                id: "session.\(recordingId).unrequested", text: "⚠︎ В запись попал звук других приложений"
            ))
        }
        return lines
    }

    static func permissionLine(_ line: PermissionOutcomeLine) -> MenuLine {
        let title = MenuBarState.permissionTitle(line.kind).capitalizedFirst
        let text: String
        switch line.outcome {
        case .granted: text = "\(title): разрешено"
        case .promptOnUse: text = "\(title): система спросит при первой записи"
        case .denied: text = "\(title): запрещено"
        case .cannotPrompt: text = "\(title): разрешить можно только в настройках"
        }
        return MenuLine(id: "permission.\(line.kind.rawValue)", text: text)
    }

    static func jobLines(_ status: AppStatus, fractions: [UUID: Double]) -> [MenuLine] {
        var lines = status.runningJobs.map { job -> MenuLine in
            let fraction = fractions[job.jobId] ?? job.fraction
            let stage = job.stage.map { " (\($0))" } ?? ""
            return MenuLine(
                id: "job.\(job.jobId.uuidString)",
                text: "\(jobTitle(job.type))\(stage): \(Int((fraction * 100).rounded()))%"
            )
        }
        if status.pendingJobCount > 0 {
            lines.append(MenuLine(id: "jobs.pending", text: "В очереди: \(status.pendingJobCount)"))
        }
        if status.failedJobCount > 0 {
            lines.append(MenuLine(id: "jobs.failed", text: "С ошибкой: \(status.failedJobCount)"))
        }
        return lines
    }

    static func errorLine(_ view: AppErrorView) -> String {
        FacadeErrorText.line(view)
    }

    static func jobTitle(_ type: JobType) -> String {
        FacadeErrorText.jobTitle(type)
    }

    /// «м:сс» до часа, «ч:мм:сс» после. Отрицательное (часы разошлись) — ноль.
    static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// Уровень 0...1 (C-004 `CaptureLevels`) — пять делений.
    static func meter(_ level: Float) -> String {
        let filled = Int((min(max(level, 0), 1) * 5).rounded())
        return String(repeating: "▮", count: filled) + String(repeating: "▯", count: 5 - filled)
    }
}
