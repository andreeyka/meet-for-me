//  SpeakerAttribution+TextCorrections — C-015 §6 (§6.3, шаг 8): постправка словарём имён.
//  Сохранение пары — не дело порта (§6, дословно); этот файл только вычисляет `TextCorrection`.

import DomainCore
import Foundation

extension SpeakerAttribution {
    /// Инв. 14: слово без уверенности не правится никогда. Инв. 15: замена только при
    /// `similarity >= nameSimilarityMin` и `original != replacement`.
    func computeTextCorrections(input: AttributionInput, thresholds: AttributionThresholds) -> [TextCorrection] {
        var corrections: [TextCorrection] = []
        for (index, segment) in input.transcript.segments.enumerated() {
            let segmentId = input.segmentIds[index]
            for (wordIndex, word) in segment.words.enumerated() {
                guard let confidence = word.confidence, confidence < thresholds.textConfidenceMax else { continue }
                guard let match = bestNameMatch(
                    for: word.text, in: input.nameForms, minimumSimilarity: thresholds.nameSimilarityMin
                ), match.form != word.text else { continue }
                corrections.append(TextCorrection(
                    segmentId: segmentId, wordIndex: wordIndex, original: word.text,
                    replacement: match.form, personId: match.personId, similarity: match.similarity
                ))
            }
        }
        return corrections
    }

    private struct NameMatch {
        let form: String
        let personId: UUID
        let similarity: Double
    }

    private func bestNameMatch(for word: String, in nameForms: [NameForm], minimumSimilarity: Double) -> NameMatch? {
        let scored = nameForms.map { form in
            NameMatch(form: form.form, personId: form.personId, similarity: phoneticSimilarity(word, form.form))
        }
        guard let best = scored.max(by: { $0.similarity < $1.similarity }), best.similarity >= minimumSimilarity else {
            return nil
        }
        return best
    }
}
