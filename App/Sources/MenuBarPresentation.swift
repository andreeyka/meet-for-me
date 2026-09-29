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

struct MenuBarPresentation: Equatable, Sendable {
    /// Строки блока активной сессии (название, время, уровни, предупреждение).
    var sessionLines: [String] = []
    /// Главная кнопка: «Начать запись» или «Остановить запись». `nil` — статуса ещё нет.
    var recordingAction: MenuAction?
    /// «Разрешить запись…» — пока `permissionsReady != .ready`.
    var permissionAction: MenuAction?
    /// Исходы последнего запроса прав и кнопки «Открыть настройки» к отказанным.
    var permissionLines: [String] = []
    var settingsActions: [MenuAction] = []
    /// Очередь: идущие задачи с долей и счётчики.
    var jobLines: [String] = []
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
            sessionLines = ["Нет активной записи"]
            recordingAction = MenuAction(title: "Начать запись", command: .startRecording, isEnabled: !busy)
        }
        if status.permissionsReady != .ready {
            permissionAction = MenuAction(
                title: "Разрешить запись…", command: .requestRecordingPermissions, isEnabled: !busy
            )
        }
        permissionLines = state.permissionOutcomes.map(Self.permissionLine)
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

    // MARK: Строки

    static func sessionLines(_ session: ActiveSessionView, now: Date) -> [String] {
        var lines = ["● \(session.title) — \(elapsed(from: session.startedAt, to: now))"]
        var levels: [String] = []
        if let mic = session.micLevel { levels.append("микрофон \(meter(mic))") }
        if let system = session.systemLevel { levels.append("система \(meter(system))") }
        if !levels.isEmpty { lines.append(levels.joined(separator: "  ")) }
        if session.containsUnrequested {
            lines.append("⚠︎ В запись попал звук других приложений")
        }
        return lines
    }

    static func permissionLine(_ line: PermissionOutcomeLine) -> String {
        let title = MenuBarState.permissionTitle(line.kind).capitalizedFirst
        switch line.outcome {
        case .granted: return "\(title): разрешено"
        case .promptOnUse: return "\(title): система спросит при первой записи"
        case .denied: return "\(title): запрещено"
        case .cannotPrompt: return "\(title): разрешить можно только в настройках"
        }
    }

    static func jobLines(_ status: AppStatus, fractions: [UUID: Double]) -> [String] {
        var lines = status.runningJobs.map { job -> String in
            let fraction = fractions[job.jobId] ?? job.fraction
            let stage = job.stage.map { " (\($0))" } ?? ""
            return "\(jobTitle(job.type))\(stage): \(Int((fraction * 100).rounded()))%"
        }
        if status.pendingJobCount > 0 { lines.append("В очереди: \(status.pendingJobCount)") }
        if status.failedJobCount > 0 { lines.append("С ошибкой: \(status.failedJobCount)") }
        return lines
    }

    static func errorLine(_ view: AppErrorView) -> String {
        let suggestion = view.recoverySuggestion.map { ". \($0)" } ?? ""
        return "Ошибка: \(view.message)\(suggestion)"
    }

    static func jobTitle(_ type: JobType) -> String {
        switch type {
        case .transcode: return "Перекодирование"
        case .transcribe: return "Транскрибация"
        case .diarize: return "Разметка говорящих"
        case .attribute: return "Опознание говорящих"
        case .summarize: return "Резюме"
        }
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

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
