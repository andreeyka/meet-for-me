//  TokenAssembler — токены распознавателя → слова и сегменты (module-map «Слова и сегменты»).
//
//  Модуль: gigaam · Владелец: DEV-2 · Слой: движок
//
//  Чистая функция. Слово — токены между границами `▁`; `startMs` — метка первого токена (у первого слова
//  куска — начало энергии `SpeechOnset`, если оно найдено: module-map «Метка первого слова куска», IR-157),
//  `endMs` — метка последнего токена слова плюс шаг кадра (40 мс). Знак препинания дописывается
//  к слову и `endMs` не двигает (CTC выдаёт его с опозданием, уже в паузе). Сегмент кончается на
//  слове со знаком `.`, `?`, `!`, `…` в конце, перед паузой ≥ 2000 мс между словами и на границе куска.
//
//  Метки токенов слов делаются строго возрастающими (`max(метка + сдвиг, предыдущая + 1)`) и не выходят
//  за последнюю миллисекунду куска, поэтому у каждого слова и сегмента `endMs > startMs`, слова идут по
//  неубыванию, не пересекаются и не выходят за конец куска (критерий 7 Z2, MEE-486).

import DomainCore

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
        /// `chunkDurationMs <= 0`: в куске нет ни одной миллисекунды для слова.
        case nonPositiveDuration(Int)
    }

    /// Собирает сегменты одного куска.
    ///
    /// - Parameters:
    ///   - chunk: результат распознавания куска.
    ///   - shiftMs: позиция куска в файле + `AudioRef.offsetMs` (инварианты 4 и 16 C-011).
    ///   - chunkDurationMs: длина куска, мс; `endMs` слова не выходит за конец куска, чтобы сегменты
    ///     соседних кусков не пересекались.
    ///   - speechOnsetMs: начало энергии в куске, мс от начала куска (`SpeechOnset.speechOnsetMs`, посчитанное
    ///     до `secondTokenMs(in:)`); заменяет метку первого токена, не являющегося знаком препинания. `nil` —
    ///     метка модели остаётся.
    static func assemble(
        _ chunk: RecognizedChunk, shiftMs: Int, chunkDurationMs: Int, channel: RecordingManifest.Channel,
        speechOnsetMs: Int?
    ) throws -> [SegmentDraft] {
        guard chunk.tokens.count == chunk.timestamps.count else {
            throw Failure.lengthMismatch(tokens: chunk.tokens.count, timestamps: chunk.timestamps.count)
        }
        guard chunkDurationMs > 0 else { throw Failure.nonPositiveDuration(chunkDurationMs) }
        let chunkEnd = shiftMs + chunkDurationMs
        let words = buildWords(chunk, shiftMs: shiftMs, chunkEndMs: chunkEnd, onsetMs: speechOnsetMs)
        return split(words, channel: channel)
    }

    /// Метка второго токена куска, не являющегося знаком препинания, мс от начала куска — граница окон
    /// `SpeechOnset`; `nil` — такой токен один или его нет (рассматривается весь кусок).
    static func secondTokenMs(in chunk: RecognizedChunk) -> Int? {
        var seen = 0
        for (token, seconds) in zip(chunk.tokens, chunk.timestamps) where isWordToken(token) {
            seen += 1
            if seen == 2 { return label(seconds) }
        }
        return nil
    }

    /// В куске есть токен, несущий метку слова (не пустой и не знак препинания).
    static func hasWordToken(in chunk: RecognizedChunk) -> Bool {
        chunk.tokens.contains(where: isWordToken)
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

    private static func buildWords(
        _ chunk: RecognizedChunk, shiftMs: Int, chunkEndMs: Int, onsetMs: Int?
    ) -> [WordDraft] {
        var words: [WordDraft] = []
        var open: OpenWord?
        var leadingPunctuation = ""
        var boundary = true
        var previousMs = Int.min / 2
        var isFirst = true

        func close() {
            guard let word = open else { return }
            // lastMs ≤ chunkEndMs − 1, поэтому end > lastMs ≥ startMs и end ≤ chunkEndMs
            let end = min(word.lastMs + frameMs, chunkEndMs)
            words.append(WordDraft(startMs: word.startMs, endMs: end, text: word.prefix + word.text))
            open = nil
        }

        for (token, seconds) in zip(chunk.tokens, chunk.timestamps) {
            let startsWord = token.first == wordMarker
            let body = String(token.drop { $0 == wordMarker })
            if startsWord { boundary = true }
            guard !body.isEmpty else { continue }
            if isPunctuation(body) {
                // знак препинания метку не несёт: endMs не двигает и следующее слово не сдвигает
                if open != nil { open?.text += body } else { leadingPunctuation += body }
                continue
            }
            // первый токен куска: начало энергии вместо кадра 0 модели (IR-157); оно строго меньше метки
            // второго токена, поэтому метки остаются строго возрастающими
            let raw = (isFirst ? onsetMs : nil) ?? label(seconds)
            isFirst = false
            // строго возрастающие метки в пределах куска: на равных метках слово не схлопнется в 0 мс
            let stamp = min(max(raw + shiftMs, previousMs + 1), chunkEndMs - 1)
            let exhausted = stamp <= previousMs
            previousMs = stamp
            if exhausted, open != nil {
                // миллисекунды куска кончились (метки за его концом): слово дописывается к открытому,
                // чтобы текст не потерялся, а границы остались внутри куска
                open?.text += boundary ? " " + body : body
                boundary = false
            } else if boundary || open == nil {
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

    /// `endMs` слова не больше `startMs` следующего. Начала слов строго возрастают, поэтому после обрезки
    /// `endMs > startMs` сохраняется.
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

    /// Токен несёт метку слова: после снятия `▁` не пуст и не знак препинания.
    private static func isWordToken(_ token: String) -> Bool {
        let body = String(token.drop { $0 == wordMarker })
        return !body.isEmpty && !isPunctuation(body)
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
