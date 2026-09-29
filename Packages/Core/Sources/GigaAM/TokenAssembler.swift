//  TokenAssembler — токены распознавателя → слова и сегменты (module-map «Слова и сегменты»).
//
//  Модуль: gigaam · Владелец: DEV-2 · Слой: движок
//
//  Чистая функция. Слово — токены между границами `▁`; `startMs` — метка первого токена,
//  `endMs` — метка последнего токена слова плюс шаг кадра (40 мс). Знак препинания дописывается
//  к слову и `endMs` не двигает (CTC выдаёт его с опозданием, уже в паузе). Сегмент кончается на
//  слове со знаком `.`, `?`, `!`, `…` в конце, перед паузой ≥ 2000 мс между словами и на границе куска.

import DomainCore
import EngineKit

/// Слово до назначения кластера.
struct WordDraft: Equatable {
    let startMs: Int
    let endMs: Int
    let text: String
}

/// Сегмент до назначения кластера: `Transcript.Segment` на `.system` без кластера не создать (C-003, инв. 6),
/// поэтому кластер приходит отдельным шагом (`ClusterAssignment`), а сегмент собирается в `makeSegment`.
struct SegmentDraft: Equatable {
    let startMs: Int
    let endMs: Int
    let channel: RecordingManifest.Channel
    let words: [WordDraft]

    /// Слова через пробел, без краевых пробелов.
    var text: String {
        words.map(\.text).joined(separator: " ")
    }

    func makeSegment(cluster: Int?, wantWordTimestamps: Bool) throws -> Transcript.Segment {
        let outWords = try wantWordTimestamps
            ? words.map { try Transcript.Word(startMs: $0.startMs, endMs: $0.endMs, text: $0.text,
                                              confidence: nil, original: nil) }
            : []
        return try Transcript.Segment(
            startMs: startMs, endMs: endMs, channel: channel, speakerCluster: cluster,
            text: text, textOriginal: nil, textConfidence: nil, words: outWords
        )
    }
}

enum TokenAssembler {

    /// Шаг кадра энкодера, мс.
    static let frameMs = 40
    /// Пауза между словами, начинающая новый сегмент, мс.
    static let segmentPauseMs = 2_000
    /// Маркер начала слова в токенах.
    static let wordMarker: Character = "\u{2581}"

    enum Failure: Error, Equatable {
        /// `tokens.count != timestamps.count`.
        case lengthMismatch(tokens: Int, timestamps: Int)
    }

    /// Собирает сегменты одного куска.
    ///
    /// - Parameters:
    ///   - chunk: результат распознавания куска.
    ///   - shiftMs: позиция куска в файле + `AudioRef.offsetMs` (инварианты 4 и 16 C-011).
    ///   - chunkDurationMs: длина куска, мс; `endMs` слова не выходит за конец куска, чтобы сегменты
    ///     соседних кусков не пересекались.
    static func assemble(
        _ chunk: RecognizedChunk, shiftMs: Int, chunkDurationMs: Int, channel: RecordingManifest.Channel
    ) throws -> [SegmentDraft] {
        guard chunk.tokens.count == chunk.timestamps.count else {
            throw Failure.lengthMismatch(tokens: chunk.tokens.count, timestamps: chunk.timestamps.count)
        }
        let chunkEnd = shiftMs + chunkDurationMs
        let words = buildWords(chunk, shiftMs: shiftMs, chunkEndMs: chunkEnd)
        return split(words, channel: channel)
    }

    /// Метка в мс: `round(сек · 1000)`.
    static func label(_ seconds: Double) -> Int {
        Int((seconds * 1_000).rounded())
    }

    private struct OpenWord {
        var prefix: String
        var text: String
        var startMs: Int
        var lastMs: Int
    }

    private static func buildWords(_ chunk: RecognizedChunk, shiftMs: Int, chunkEndMs: Int) -> [WordDraft] {
        var words: [WordDraft] = []
        var open: OpenWord?
        var leadingPunctuation = ""
        var boundary = true
        var previousMs = Int.min

        func close() {
            guard let word = open else { return }
            let end = max(min(word.lastMs + frameMs, chunkEndMs), word.startMs + 1)
            words.append(WordDraft(startMs: word.startMs, endMs: end, text: word.prefix + word.text))
            open = nil
        }

        for (token, seconds) in zip(chunk.tokens, chunk.timestamps) {
            let startsWord = token.first == wordMarker
            let body = String(token.drop { $0 == wordMarker })
            if startsWord { boundary = true }
            guard !body.isEmpty else { continue }
            let stamp = max(label(seconds) + shiftMs, previousMs)
            previousMs = stamp
            if isPunctuation(body) {
                if open != nil { open?.text += body } else { leadingPunctuation += body }
                continue
            }
            if boundary || open == nil {
                close()
                open = OpenWord(prefix: leadingPunctuation, text: body, startMs: stamp, lastMs: stamp)
                leadingPunctuation = ""
                boundary = false
            } else {
                open?.text += body
                open?.lastMs = stamp
            }
        }
        close()
        return clampOverlaps(words)
    }

    /// `endMs` слова не больше `startMs` следующего (на равных метках соседних кадров).
    private static func clampOverlaps(_ words: [WordDraft]) -> [WordDraft] {
        var result = words
        for position in result.indices.dropLast() where result[position].endMs > result[position + 1].startMs {
            let word = result[position]
            result[position] = WordDraft(
                startMs: word.startMs, endMs: result[position + 1].startMs, text: word.text
            )
        }
        return result
    }

    private static func isPunctuation(_ body: String) -> Bool {
        body.allSatisfy { $0.isPunctuation || $0.isSymbol }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…".contains(last)
    }

    private static func split(_ words: [WordDraft], channel: RecordingManifest.Channel) -> [SegmentDraft] {
        var segments: [SegmentDraft] = []
        var current: [WordDraft] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(SegmentDraft(startMs: first.startMs, endMs: last.endMs, channel: channel, words: current))
            current = []
        }

        for word in words {
            if let previous = current.last, word.startMs - previous.endMs >= segmentPauseMs { flush() }
            current.append(word)
            if endsSentence(word.text) { flush() }
        }
        flush()
        return segments
    }
}
