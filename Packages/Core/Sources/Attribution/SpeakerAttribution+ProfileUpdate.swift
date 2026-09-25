//  SpeakerAttribution+ProfileUpdate — C-015 инв. 9/10: только `confirm` меняет голосовые
//  профили, и только при `voiceProfilesEnabled == true`.

import DomainCore
import Foundation

extension SpeakerAttribution {
    /// Инв. 10: при `voiceProfilesEnabled == false` — пусто, обучение не происходит (случай
    /// «выключено» не бросает `voiceProfilesDisabled` — решение возврата IR-128, «Поведение»).
    /// Без эмбеддинга у кластера обновлять профиль нечем — тоже пусто, не отказ.
    /// Существующий профиль — взвешенное среднее (вес `sampleCount` : 1), нормированное к
    /// единичной длине, `sampleCount + 1`. Профиля ещё нет — новый, `sampleCount == 1`,
    /// эмбеддинг кластера как есть (нормированный): контракт называет только формулу для
    /// «прежнего» профиля, случай первого подтверждения — выбор реализации, взятый как
    /// частный случай той же формулы с прежним профилем, равным нулевому вектору весом 0.
    func confirmedProfileUpdates(cluster: Int, personId: UUID, input: AttributionInput) -> [SpeakerProfileUpdate] {
        guard input.voiceProfilesEnabled else { return [] }
        guard let speaker = input.transcript.speakers.first(where: { $0.cluster == cluster }),
              let clusterEmbedding = speaker.embedding else {
            return []
        }

        if let existing = input.profiles.first(where: { $0.personId == personId }) {
            let merged = weightedAverage(
                existing.embedding, weight: Double(existing.sampleCount), clusterEmbedding, weight: 1.0
            )
            return [SpeakerProfileUpdate(
                personId: personId, embedding: normalized(merged),
                modelVersion: input.embeddingModelVersion, sampleCount: existing.sampleCount + 1
            )]
        }
        return [SpeakerProfileUpdate(
            personId: personId, embedding: normalized(clusterEmbedding),
            modelVersion: input.embeddingModelVersion, sampleCount: 1
        )]
    }

    private func weightedAverage(
        _ lhs: [Float], weight lhsWeight: Double, _ rhs: [Float], weight rhsWeight: Double
    ) -> [Float] {
        let totalWeight = lhsWeight + rhsWeight
        return zip(lhs, rhs).map { lhsValue, rhsValue in
            Float((Double(lhsValue) * lhsWeight + Double(rhsValue) * rhsWeight) / totalWeight)
        }
    }

    private func normalized(_ vector: [Float]) -> [Float] {
        let length = (vector.reduce(0.0) { $0 + Double($1) * Double($1) }).squareRoot()
        guard length > 0 else { return vector }
        return vector.map { Float(Double($0) / length) }
    }
}
