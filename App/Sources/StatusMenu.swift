//  StatusMenu — минимум статуса из `AppFacade.status()` (MEE-433, «MenuBarExtra показывает
//  минимум статуса») + пункт «Завершить» (М1, возврат РП — без Dock-иконки у приложения нет
//  штатного выхода). Экраны (окно встреч, просмотр транскрипта, настройки, мастер прав) —
//  отдельная задача; этот файл — не она.
//
//  Статус — из `appDelegate.status`, не из собственного `.task`: подписка на
//  `AppFacade.events()` (М4, возврат РП) живёт на `AppDelegate`, не на этом виде — в
//  menu-стиле `MenuBarExtra` вид пересобирается при каждом открытии меню.
//
//  Возврат РП назвал `AppFacade.events()` рабочей заменой обновлению при открытии — но
//  сегодня в domain-core `AppEvent.statusChanged` нигде не публикуется (сверено: `grep` по
//  `.statusChanged(` в `Packages/Core/Sources/DomainCore` — ноль совпадений; публикуется
//  только `.settingsChanged`, `AppFacadeImpl+Settings.swift:131`). Подписка в `AppDelegate`
//  остаётся — начнёт работать сама, когда эта публикация появится, — но пока единственный
//  путь не застрять на «Загрузка статуса…» это тоже обновление на открытии: `.onAppear`
//  ниже, не `.task(id:)` (тот привязан к разовому условию «граф появился», а не к каждому
//  открытию меню).

import AppKit
import DomainCore
import SwiftUI

struct StatusMenu: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        Group {
            if appDelegate.graph == nil {
                Text("Запуск…")
            } else if let status = appDelegate.status {
                Text(summary(for: status))
            } else {
                Text("Загрузка статуса…")
            }
            Button("Обновить") {
                Task { await appDelegate.refreshStatus() }
            }
            Divider()
            Button("Завершить") {
                NSApp.terminate(nil)
            }
        }
        .onAppear {
            Task { await appDelegate.refreshStatus() }
        }
    }

    private func summary(for status: AppStatus) -> String {
        var parts = [status.activeSession == nil ? "нет активной сессии" : "идёт запись"]
        if status.pendingJobCount > 0 {
            parts.append("\(status.pendingJobCount) задач в очереди")
        }
        if status.failedJobCount > 0 {
            parts.append("\(status.failedJobCount) отказавших")
        }
        return parts.joined(separator: ", ")
    }
}
