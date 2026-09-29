//  MenuBarController — исполняет `MenuCommand` против `AppFacade` и держит `MenuBarState`
//  на времени жизни `AppDelegate` (MEE-473). Не держит логики «что показать» — она в
//  `MenuBarModel.swift`/`MenuBarPresentation.swift`; здесь только `await` и подписка.
//
//  Почему не `.task` вида: в menu-стиле `MenuBarExtra` вид пересобирается на каждое открытие
//  меню (шапка `StatusMenu.swift`), подписка и таймер переживают это только на объекте,
//  которым владеет делегат.
//
//  Пока идёт запись — опрос `status()` раз в секунду: время записи должно идти, а уровни
//  (`ActiveSessionView.micLevel`/`systemLevel`) фасад не публикует отдельным
//  `AppEvent.statusChanged` — только отдаёт в следующем `status()` (`AppFacadeImpl+ActiveSession`,
//  `.levels` не публикует). Без записи опроса нет: хватает `events()` и обновления на открытии.
//
//  П7: только `AppFacade`, ни `Storage`, ни движка, ни адаптеров.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

@MainActor
final class MenuBarController: ObservableObject {

    @Published private(set) var state = MenuBarState()
    @Published private(set) var now = Date()

    private let facade: AppFacade
    private var eventsTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    init(facade: AppFacade) {
        self.facade = facade
    }

    var presentation: MenuBarPresentation {
        MenuBarPresentation(state: state, now: now)
    }

    /// Подписка на `events()` на всё время жизни контроллера + первый снимок.
    func start() {
        guard eventsTask == nil else { return }
        let stream = facade.events()
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.state.apply(event: event)
                self.updateTicker()
            }
        }
        Task { await refresh() }
    }

    func stop() {
        eventsTask?.cancel()
        tickTask?.cancel()
        eventsTask = nil
        tickTask = nil
    }

    /// Снимок по запросу: на открытии меню и после каждой команды — на случай, если поток
    /// `events()` пропустил снимок (наблюдаемость сверх подписки, не замена ей).
    func refresh() async {
        state.apply(status: await facade.status())
        now = Date()
        updateTicker()
    }

    func dismissError() {
        state.dismissError()
    }

    /// Нажатие. Пока предыдущая команда не ответила, новое нажатие ничего не шлёт.
    func perform(_ command: MenuCommand) {
        guard state.begin(command) else { return }
        Task {
            let result = await execute(command)
            state.finish(command, result: result)
            await refresh()
        }
    }

    private func execute(_ command: MenuCommand) async -> MenuCommandResult {
        do {
            switch command {
            case .startRecording:
                _ = try await facade.startRecording(meetingId: nil)
            case .stopRecording(let recordingId):
                try await facade.stopRecording(recordingId: recordingId)
            case .requestRecordingPermissions:
                var lines: [PermissionOutcomeLine] = []
                for kind in MenuBarState.recordingPermissionKinds {
                    lines.append(PermissionOutcomeLine(kind: kind, outcome: await facade.requestPermission(kind)))
                }
                return .permissionsRequested(lines)
            case .openPermissionSettings(let kind):
                try await facade.openPermissionSettings(kind)
            }
            return .succeeded
        } catch {
            return .failed(MenuBarState.errorView(for: error))
        }
    }

    private func updateTicker() {
        let recording = state.status?.activeSession != nil
        if recording, tickTask == nil {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    await self.refresh()
                }
            }
        } else if !recording, let task = tickTask {
            task.cancel()
            tickTask = nil
        }
    }
}
