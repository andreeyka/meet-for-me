//  InMemoryTranscriptRepository.applyTextCorrections — C-010 v19, инвариант 32 (IR-129,
//  MEE-388). Разведено в отдельный файл по объёму (`file_length`), не по смыслу:
//  `InMemoryTranscriptRepository.swift` с этим разделом внутри перерастал предел SwiftLint
//  (400 строк) — тот же приём, что `GRDBTranscriptRepositoryWrite.swift`/`…Mapping.swift`
//  для GRDB-стороны того же порта.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)

import DomainCore

extension InMemoryTranscriptRepository {

    /// Инвариант 32 дословно: `is_user_edited = 1` — строка молча не трогается (не отказ);
    /// чужой `segmentId` либо `wordIndex` вне диапазона — `constraintViolation`, строка не
    /// меняется НИ В ОДНОМ поле; пустой `corrections` — не отказ, `words` не трогается;
    /// несуществующий `segmentId` — `notFound`.
    public func applyTextCorrections(
        segmentId: Int64, text: String, corrections: [TextCorrection]
    ) async throws {
        log.record(
            port: Self.portName,
            method: "applyTextCorrections(segmentId:text:corrections:)",
            arguments: [String(segmentId), text] + corrections.map { String($0.wordIndex) }
        )
        if let error = failureIfAny(.applyTextCorrections, id: String(segmentId)) {
            throw error
        }
        switch locked({ applyCorrections(segmentId, text, corrections) }) {
        case .replaced, .skippedUserEdited:
            return
        case .notFound:
            throw StorageError.notFound(entity: "Segment", id: String(segmentId))
        case .invalidCorrection(let message):
            throw StorageError.constraintViolation(message: message)
        case .invalid(let message):
            throw StorageError.dataCorrupted(entity: "Segment", id: String(segmentId), message: message)
        }
    }

    /// Исход применения постправки.
    private enum TextCorrectionApplication {
        case replaced
        case skippedUserEdited
        case notFound
        case invalidCorrection(String)
        case invalid(String)
    }

    /// Зовётся под замком. Валидация — до записи: чужой `segmentId` либо `wordIndex` вне
    /// диапазона отклоняет ВСЮ правку, строка не меняется ни в одном поле.
    private func applyCorrections(
        _ segmentId: Int64, _ text: String, _ corrections: [TextCorrection]
    ) -> TextCorrectionApplication {
        for (transcriptId, rows) in rowsByTranscript {
            guard let index = rows.firstIndex(where: { $0.id == segmentId }) else { continue }
            let row = rows[index]
            guard !row.isUserEdited else { return .skippedUserEdited }
            let segment = row.segment
            for correction in corrections {
                guard correction.segmentId == segmentId else {
                    return .invalidCorrection(
                        "correction.segmentId (\(correction.segmentId)) != segmentId (\(segmentId))"
                    )
                }
                guard segment.words.indices.contains(correction.wordIndex) else {
                    return .invalidCorrection(
                        "wordIndex (\(correction.wordIndex)) вне диапазона words (\(segment.words.count))"
                    )
                }
            }
            let replaced: Transcript.Segment
            do {
                replaced = try replacing(segment, text: text, corrections: corrections)
            } catch {
                return .invalid(String(describing: error))
            }
            rowsByTranscript[transcriptId]?[index] = SegmentRow(
                id: row.id, transcriptId: row.transcriptId, segment: replaced,
                personId: row.personId, speakerConfidence: row.speakerConfidence,
                attributionSource: row.attributionSource, isUserEdited: false
            )
            return .replaced
        }
        return .notFound
    }

    /// Бросает только по построению (не должно происходить на живом входе): значения,
    /// кроме `text`/`.original`, берутся у уже валидного слова/сегмента без изменений.
    private func replacing(
        _ segment: Transcript.Segment, text: String, corrections: [TextCorrection]
    ) throws -> Transcript.Segment {
        var words = segment.words
        for correction in corrections where words[correction.wordIndex].original == nil {
            let word = words[correction.wordIndex]
            words[correction.wordIndex] = try Transcript.Word(
                startMs: word.startMs, endMs: word.endMs, text: correction.replacement,
                confidence: word.confidence, original: correction.original
            )
        }
        return try Transcript.Segment(
            startMs: segment.startMs, endMs: segment.endMs, channel: segment.channel,
            speakerCluster: segment.speakerCluster, text: text,
            textOriginal: segment.textOriginal ?? segment.text,
            textConfidence: segment.textConfidence, words: words
        )
    }
}
