//  AppDelegate — строит composition root при запуске, показывает отказ и завершает процесс
//  на сломанном окружении, останавливает граф при выходе (MEE-433, MEE-430 «жизненный
//  цикл»).
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                graph = try await CompositionRoot.build()
            } catch {
                Self.presentStartupFailureAndTerminate(error)
            }
        }
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
        alert.runModal()
        NSApp.terminate(nil)
    }
}
