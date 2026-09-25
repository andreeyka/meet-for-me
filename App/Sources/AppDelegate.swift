//  AppDelegate — строит composition root при запуске, показывает отказ и завершает процесс
//  на сломанном окружении, останавливает граф при выходе (MEE-433, MEE-430 «жизненный
//  цикл»). Владеет статусом меню-бара (М4, возврат РП): подписка на `AppFacade.events()`
//  живёт на времени жизни делегата, не на времени жизни `StatusMenu` — в menu-стиле
//  `MenuBarExtra` вид пересобирается при каждом открытии меню, и `.task` внутри него не
//  гарантированно переживает это пересоздание.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import AppKit
import DomainCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    /// `nil` до готовности графа (`applicationDidFinishLaunching` асинхронен) и на всё время
    /// жизни приложения после — `CompositionRoot.build()` либо отдаёт готовый граф, либо
    /// приложение уже завершилось (`presentStartupFailureAndTerminate`).
    @Published private(set) var graph: AppGraph?

    /// Минимум статуса для `StatusMenu` (МЕЕ-433). `nil` — ещё не пришёл ни один снимок
    /// (граф не готов или первый `status()` не отработал).
    @Published private(set) var status: AppStatus?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let graph = try await CompositionRoot.build()
                self.graph = graph
                await refreshStatus()
                observeStatus(graph.facade)
            } catch {
                Self.presentStartupFailureAndTerminate(error)
            }
        }
    }

    /// М4 (возврат РП): держит `status` свежим, пока приложение живо — независимо от того,
    /// открыто меню сейчас или нет.
    private func observeStatus(_ facade: AppFacade) {
        Task {
            for await event in facade.events() {
                if case .statusChanged(let newStatus) = event {
                    status = newStatus
                }
            }
        }
    }

    /// Вызывается кнопкой «Обновить» в `StatusMenu` — на случай, если поток `events()`
    /// пропустил снимок (наблюдаемость сверх подписки, не замена ей).
    func refreshStatus() async {
        guard let graph else { return }
        status = await graph.facade.status()
    }

    /// `.terminateLater` — `AppGraph.shutdown()` асинхронен (`SessionCoordinator.stop()`,
    /// `JobQueueEngine.stop()`), а `NSApplicationDelegate` не даёт async-варианта этого
    /// метода. Без графа (отказ на старте уже завершил процесс раньше) завершать нечего.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let graph else { return .terminateNow }
        Task {
            await graph.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Отказ `StorageDatabase`/`SignalWeights`/настроек на старте — сломанное окружение, не
    /// пользовательское состояние (решение архитектора, MEE-430 «жизненный цикл»): нативный
    /// блокирующий alert (не через `AppFacade` — его на этом шаге ещё нет) и завершение, а не
    /// тихое продолжение с пустышкой.
    private static func presentStartupFailureAndTerminate(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Meet for Me не может запуститься"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "Завершить")
        // М2 (возврат РП): без Dock-иконки (LSUIElement) у приложения нет активного окна,
        // которое подняло бы alert само — без явной активации он мог бы остаться позади
        // других приложений.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }
}
