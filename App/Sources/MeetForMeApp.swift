//  MeetForMeApp
//
//  Модуль: app-ui · Владелец: DEV-1 (module-map.md v1.21, MEE-430) · Слой: UI
//
//  Каталог принадлежит владельцу модуля: файлы здесь изменяет только он (П1).
//  Всё, что пересекает границу модуля, описано контрактом архитектора и меняется
//  только через interface-request (П2, П6). Границы и запреты — docs/module-map.md.
//
//  Каркас (MEE-430): точка входа собирается и запускается (menu-bar-иконка без окон,
//  architecture.md §9.2 — LSUIElement), но ничего не делает. Composition root (создание
//  StorageDatabase/AudioCaptureImpl/MeetingDetector/CalendarPortImpl/SessionMachine/
//  AppFacadeImpl и связывание AppFacade с экранами) и сами экраны (меню-бар, окно встреч,
//  просмотр транскрипта, настройки, мастер прав) — предмет следующей задачи DEV-1,
//  постановка которой — комментарий архитектора в MEE-430.

import SwiftUI

@main
struct MeetForMeApp: App {
    var body: some Scene {
        MenuBarExtra("Meet for Me", systemImage: "mic.circle") {
            Text("Каркас MEE-430 — composition root и экраны добавит DEV-1.")
        }
    }
}
