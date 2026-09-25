//  MeetForMeApp
//
//  Модуль: app-ui · Владелец: DEV-1 (module-map.md v1.21, MEE-430) · Слой: UI
//
//  Каталог принадлежит владельцу модуля: файлы здесь изменяет только он (П1).
//  Всё, что пересекает границу модуля, описано контрактом архитектора и меняется
//  только через interface-request (П2, П6). Границы и запреты — docs/module-map.md.
//
//  Composition root (MEE-433, `CompositionRoot.swift`) строит граф домена при запуске
//  (`AppDelegate.applicationDidFinishLaunching`) и отдаёт единственный `AppFacade`.
//  Сами экраны (окно встреч, просмотр транскрипта, настройки, мастер прав) — предмет
//  следующей задачи DEV-1; `StatusMenu` здесь несёт только минимум статуса (MEE-433).

import SwiftUI

@main
struct MeetForMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Meet for Me", systemImage: "mic.circle") {
            StatusMenu(appDelegate: appDelegate)
        }
    }
}
