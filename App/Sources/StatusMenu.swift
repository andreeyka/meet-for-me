//  StatusMenu — минимум статуса из `AppFacade.status()` (MEE-433, «MenuBarExtra показывает
//  минимум статуса»). Экраны (окно встреч, просмотр транскрипта, настройки, мастер прав) —
//  отдельная задача; этот файл — не она.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import SwiftUI

struct StatusMenu: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var status: AppStatus?

    var body: some View {
        Group {
            if let facade = appDelegate.graph?.facade {
                if let status {
                    Text(summary(for: status))
                } else {
                    Text("Загрузка статуса…")
                }
                Button("Обновить") {
                    Task { status = await facade.status() }
                }
            } else {
                Text("Запуск…")
            }
        }
        .task(id: appDelegate.graph != nil) {
            guard let facade = appDelegate.graph?.facade else { return }
            status = await facade.status()
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
