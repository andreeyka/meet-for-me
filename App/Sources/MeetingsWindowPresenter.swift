//  MeetingsWindowPresenter — открывает и закрывает окно «Встречи» (MEE-474). Владеет им
//  `AppDelegate`; пункт меню-бара «Открыть встречи…» зовёт `show()`.
//
//  Окно — `NSWindow` с `NSHostingController`, а не сцена `Window` SwiftUI: у `LSUIElement`
//  приложения без Dock-иконки окно надо явно поднять (`NSApp.activate`), а время жизни
//  контроллера — привязать ровно к окну. `MeetingsController` создаётся при открытии и
//  останавливается и отпускается при закрытии: окно не держит данных дольше своей жизни.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import AppKit
import DomainCore
import SwiftUI

@MainActor
final class MeetingsWindowPresenter: NSObject, NSWindowDelegate {

    private let facade: AppFacade
    private var window: NSWindow?
    private var controller: MeetingsController?

    init(facade: AppFacade) {
        self.facade = facade
    }

    func show() {
        if window == nil {
            let controller = MeetingsController(facade: facade)
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: MeetingsWindowView(controller: controller)
            ))
            window.title = "Встречи"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1080, height: 680))
            window.center()
            window.delegate = self
            self.window = window
            self.controller = controller
            controller.start()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    /// `nonisolated` + `assumeIsolated`: `NSWindowDelegate` вызывается на главном потоке, а
    /// изоляция протокола в разных SDK объявлена по-разному (CI — Xcode 15.4).
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller?.stop()
            controller = nil
            window?.delegate = nil
            window = nil
        }
    }
}
