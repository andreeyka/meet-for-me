//  StatusMenu — меню-бар (MEE-433 минимум статуса; MEE-473 ручной старт/стоп, активная
//  сессия, права на запись, отказы, идущие задачи) + пункт «Завершить» (М1, возврат РП — без
//  Dock-иконки у приложения нет штатного выхода). Окно встреч и просмотр транскрипта —
//  `MeetingsWindow*.swift` (MEE-474); настройки и полный мастер прав — отдельные задачи.
//
//  Вид ничего не решает сам: что показать и какая команда уходит по нажатию — в
//  `MenuBarPresentation` (чистая модель, `MenuBarModel.swift`/`MenuBarPresentation.swift`),
//  состояние и подписка на `AppFacade.events()` — в `MenuBarController`, которым владеет
//  `AppDelegate`: в menu-стиле `MenuBarExtra` вид пересобирается при каждом открытии меню,
//  и `.task` внутри него не гарантированно переживает это пересоздание.
//
//  `.onAppear` — обновление на каждом открытии меню сверх подписки (наблюдаемость на случай
//  пропущенного снимка), не `.task(id:)`: тот привязан к разовому условию. `.onDisappear`
//  выключает опрос `status()` на время записи (MEE-478 п. 5, `MenuBarController`).
//
//  «Открыть встречи…» — окно «Встречи» (MEE-474), им владеет `AppDelegate`
//  (`MeetingsWindowPresenter`).

import AppKit
import DomainCore
import SwiftUI

struct StatusMenu: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        Group {
            if let menu = appDelegate.menu {
                StatusMenuContent(controller: menu)
                Divider()
                Button("Открыть встречи…") { appDelegate.showMeetings() }
            } else {
                Text("Запуск…")
            }
            Divider()
            Button("Завершить") {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct StatusMenuContent: View {
    @ObservedObject var controller: MenuBarController

    var body: some View {
        let presentation = controller.presentation
        Group {
            if let placeholder = presentation.placeholder {
                Text(placeholder)
            }
            ForEach(presentation.sessionLines) { Text($0.text) }
            if let action = presentation.recordingAction {
                actionButton(action)
            }
            if let action = presentation.permissionAction {
                Divider()
                actionButton(action)
            }
            ForEach(presentation.permissionLines) { Text($0.text) }
            if !presentation.jobLines.isEmpty {
                Divider()
                ForEach(presentation.jobLines) { Text($0.text) }
            }
            if let errorLine = presentation.errorLine {
                Divider()
                Text(errorLine)
                Button("Скрыть ошибку") { controller.dismissError() }
            }
            ForEach(presentation.settingsActions) { actionButton($0) }
            Divider()
            Button("Обновить") {
                Task { await controller.refresh() }
            }
        }
        .onAppear { controller.menuOpened() }
        .onDisappear { controller.menuClosed() }
    }

    private func actionButton(_ action: MenuAction) -> some View {
        Button(action.title) { controller.perform(action.command) }
            .disabled(!action.isEnabled)
    }
}
