//  TranscriptPresentation — просмотр транскрипта в окне «Встречи» (MEE-474 п. 3), только
//  чтение. Чистая функция от `MeetingsWindowState`, без SwiftUI.
//
//  Сегменты — в порядке фасада (C-016 инв. 5: по `startMs`). Спикер — `speakerDisplayName`
//  (пока атрибуции нет, это «Спикер N») и канал `.mic`/`.system`. Слова с низкой уверенностью
//  (`lowConfidenceWordIndexes`, инв. 8) отмечаются, если сегмент не правился руками: после
//  правки `words` текст уже не описывают.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

struct TranscriptToken: Equatable, Sendable, Identifiable {
    let id: Int
    let text: String
    let isLowConfidence: Bool
}

struct TranscriptSegmentRow: Equatable, Sendable, Identifiable {
    let id: Int64
    let time: String
    let speaker: String
    /// Текст по словам с отметкой неуверенных. Пусто — показывать `text` целиком.
    let tokens: [TranscriptToken]
    let text: String

    init(segment: SegmentView) {
        id = segment.segmentId
        time = MeetingsFormat.offset(ms: segment.startMs)
        speaker = "\(segment.speakerDisplayName) · \(Self.channelTitle(segment.channel))"
        text = segment.text
        tokens = Self.tokens(segment)
    }

    static func channelTitle(_ channel: RecordingManifest.Channel) -> String {
        switch channel {
        case .mic: return "микрофон"
        case .system: return "система"
        }
    }

    static func tokens(_ segment: SegmentView) -> [TranscriptToken] {
        let low = Set(segment.lowConfidenceWordIndexes)
        guard !segment.isUserEdited, !low.isEmpty, !segment.words.isEmpty else { return [] }
        return segment.words.enumerated().map { index, word in
            TranscriptToken(id: index, text: word.text, isLowConfidence: low.contains(index))
        }
    }
}

struct TranscriptPresentation: Equatable, Sendable {
    /// Версии транскрипта выбранной записи; первая — «Последняя».
    var versions: [TranscriptVersionRow] = []
    var selection: TranscriptSelection = .latest
    var segments: [TranscriptSegmentRow] = []
    /// Заглушка вместо текста.
    var placeholder: String?
    var isError = false
    /// У заглушки есть «Повторить загрузку»: отказ или прерванное чтение (MEE-492 п. C1).
    var canRetry = false
    /// Блок транскрипта вообще не показывается (запись не выбрана или транскрипта нет —
    /// тогда показан блок обработки).
    var isHidden = true

    init(state: MeetingsWindowState, card: MeetingCardPresentation) {
        guard let recordingId = state.selectedRecordingId,
              let recording = card.recordings.first(where: { $0.id == recordingId }),
              !recording.transcriptVersions.isEmpty else { return }
        isHidden = false
        versions = recording.transcriptVersions
        selection = state.transcriptSelection
        switch state.transcript {
        case .none, .loading:
            placeholder = "Загрузка транскрипта…"
        case .missing:
            placeholder = "Транскрипт не найден"
        case .failed(let error):
            placeholder = FacadeErrorText.line(error)
            isError = true
            canRetry = true
        case .interrupted:
            placeholder = InterruptedReadText.placeholder
            canRetry = true
        case .loaded(let view):
            segments = view.segments.map(TranscriptSegmentRow.init(segment:))
            if segments.isEmpty { placeholder = "В транскрипте нет речи" }
        }
    }
}
