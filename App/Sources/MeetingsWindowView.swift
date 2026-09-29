//  MeetingsWindowView — окно «Встречи» (MEE-474): слева список недели, справа карточка
//  встречи, записи, состояние обработки и транскрипт. Только чтение, кроме «Повторить». В
//  списке — встречи и записи без встречи («Созвон без события», MEE-487) одной таблицей.
//
//  Вид ничего не решает сам: что показать — `MeetingsListPresentation`,
//  `MeetingCardPresentation`, `TranscriptPresentation` (чистые модели); состояние и подписка —
//  `MeetingsController`, которым владеет `MeetingsWindowPresenter` на время жизни окна.
//
//  `@MainActor` у видов явно: в SDK Xcode 15.4 (CI, Swift 5.10) `View` изолирован только в
//  `body`, а вспомогательные свойства зовут методы `@MainActor`-контроллера.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import SwiftUI

@MainActor
struct MeetingsWindowView: View {
    @ObservedObject var controller: MeetingsController

    var body: some View {
        let list = MeetingsListPresentation(state: controller.state)
        let card = MeetingCardPresentation(state: controller.state)
        let transcript = TranscriptPresentation(state: controller.state, card: card)
        HSplitView {
            MeetingsListPane(list: list, controller: controller)
                .frame(minWidth: 480, maxHeight: .infinity)
            MeetingCardPane(card: card, transcript: transcript, controller: controller)
                .frame(minWidth: 400, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 540)
    }
}

// MARK: - Список

@MainActor
private struct MeetingsListPane: View {
    let list: MeetingsListPresentation
    let controller: MeetingsController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { controller.showPreviousWeek() } label: { Image(systemName: "chevron.left") }
                Text(list.weekTitle).font(.headline)
                Button { controller.showNextWeek() } label: { Image(systemName: "chevron.right") }
                Spacer()
                Button("Эта неделя") { controller.showCurrentWeek() }
            }
            .padding(10)
            Divider()
            if let placeholder = list.placeholder {
                PlaceholderView(text: placeholder, isError: list.isError) { controller.retryReads() }
            } else {
                table
            }
            if let adHocError = list.adHocError {
                Divider()
                HStack {
                    Text(adHocError).foregroundStyle(.red)
                    Spacer()
                    Button("Повторить загрузку") { controller.retryReads() }
                }
                .padding(10)
            }
        }
    }

    private var table: some View {
        Table(list.rows, selection: selection) {
            TableColumn("Название", value: \.title)
            TableColumn("Время", value: \.time)
            TableColumn("Статус", value: \.status)
            TableColumn("Запись", value: \.recording)
            TableColumn("Транскрипт", value: \.transcript)
            TableColumn("Отмена", value: \.cancelled)
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { list.selectedRowId },
            set: { controller.select(row: list.kind(forRowId: $0)) }
        )
    }
}

// MARK: - Карточка

@MainActor
private struct MeetingCardPane: View {
    let card: MeetingCardPresentation
    let transcript: TranscriptPresentation
    let controller: MeetingsController

    var body: some View {
        if let placeholder = card.placeholder {
            PlaceholderView(text: placeholder, isError: card.isError) { controller.retryReads() }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                Divider()
                recordings
                if !transcript.isHidden {
                    TranscriptPane(transcript: transcript, controller: controller)
                } else {
                    Spacer()
                }
            }
            .padding(12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title).font(.title2).textSelection(.enabled)
            Text("\(card.time) · \(card.status)").foregroundStyle(.secondary)
            if let organizer = card.organizer {
                Text("Организатор: \(organizer)")
            }
            if !card.attendees.isEmpty {
                Text("Участники: \(card.attendees.joined(separator: ", "))")
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if let actionError = card.actionError {
                HStack {
                    Text(actionError).foregroundStyle(.red)
                    Button("Скрыть") { controller.dismissActionError() }
                }
            }
            if let processingError = card.processingError {
                Text(processingError).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var recordings: some View {
        if card.recordings.isEmpty {
            Text("Записей нет").foregroundStyle(.secondary)
        } else {
            Picker("Запись", selection: recordingSelection) {
                ForEach(card.recordings) { Text($0.title).tag(Optional($0.id)) }
            }
            if let processing = card.recordings.first(where: { $0.id == card.selectedRecordingId })?.processing {
                HStack {
                    Text(processing.text).foregroundStyle(processing.isFailure ? .red : .secondary)
                    if let jobId = processing.retryJobId {
                        Button("Повторить") { controller.retry(jobId: jobId) }
                            .disabled(!processing.isRetryEnabled)
                    }
                }
            }
        }
    }

    /// `UUID?` (MEE-487 п. 10): пока запись не выбрана, `Picker` показывает пустой выбор, а не
    /// выдуманный `UUID()`, которого нет среди тегов.
    private var recordingSelection: Binding<UUID?> {
        Binding(
            get: { card.selectedRecordingId },
            set: { recordingId in
                guard let recordingId else { return }
                controller.select(recordingId: recordingId)
            }
        )
    }
}

// MARK: - Транскрипт

@MainActor
private struct TranscriptPane: View {
    let transcript: TranscriptPresentation
    let controller: MeetingsController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Версия", selection: versionSelection) {
                Text("Последняя").tag(TranscriptSelection.latest)
                ForEach(transcript.versions) { Text($0.title).tag(TranscriptSelection.version($0.id)) }
            }
            if let placeholder = transcript.placeholder {
                PlaceholderView(text: placeholder, isError: transcript.isError) { controller.retryTranscript() }
            } else {
                List(transcript.segments) { SegmentRowView(row: $0) }
            }
        }
    }

    private var versionSelection: Binding<TranscriptSelection> {
        Binding(get: { transcript.selection }, set: { controller.select(transcript: $0) })
    }
}

private struct SegmentRowView: View {
    let row: TranscriptSegmentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(row.time).monospacedDigit().foregroundStyle(.secondary)
                Text(row.speaker).bold()
            }
            text.textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    /// Неуверенные слова — подчёркнуты и окрашены (C-016 инв. 8).
    private var text: Text {
        guard !row.tokens.isEmpty else { return Text(row.text) }
        return row.tokens.reduce(Text("")) { result, token in
            result + Text((token.id == 0 ? "" : " ") + token.text)
                .underline(token.isLowConfidence)
                .foregroundColor(token.isLowConfidence ? .orange : nil)
        }
    }
}

// MARK: - Заглушка

private struct PlaceholderView: View {
    let text: String
    let isError: Bool
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(text)
                .foregroundStyle(isError ? .red : .secondary)
                .multilineTextAlignment(.center)
            if isError, let retry {
                Button("Повторить загрузку", action: retry)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
