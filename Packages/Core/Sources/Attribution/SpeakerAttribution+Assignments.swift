//  SpeakerAttribution+Assignments — C-015 §5, правила 2–4 («первое сработавшее побеждает»).
//  Правило 1 (микрофонный канал) сюда не входит: оно не адресуется кластером и живёт только
//  в `segmentUpdates` (инв. 21а) — см. SpeakerAttribution+SegmentUpdates.

import DomainCore

extension SpeakerAttribution {
    /// Инв. 4: ровно по одному элементу на каждый `cluster` из `transcript.speakers`.
    /// `override` — решение `confirm`/`reject` для одного кластера, минуя правила 2–4.
    func computeAssignments(
        input: AttributionInput,
        thresholds: AttributionThresholds,
        override: SpeakerAssignment?
    ) throws -> [SpeakerAssignment] {
        let systemClusterCount = input.transcript.speakers.count
        return try input.transcript.speakers.map { speaker in
            if let override, override.cluster == speaker.cluster {
                return override
            }
            return try assignCluster(
                speaker: speaker, input: input, thresholds: thresholds, systemClusterCount: systemClusterCount
            )
        }
    }

    private func assignCluster(
        speaker: Transcript.Speaker,
        input: AttributionInput,
        thresholds: AttributionThresholds,
        systemClusterCount: Int
    ) throws -> SpeakerAssignment {
        if let byProfile = try matchVoiceProfile(speaker: speaker, profiles: input.profiles, thresholds: thresholds) {
            return byProfile
        }
        if let byMeeting = matchOneOnOne(
            speaker: speaker, attendees: input.attendees, me: input.me, systemClusterCount: systemClusterCount
        ) {
            return byMeeting
        }
        // Правило 4: «voiceProfile, если профили сравнивались, иначе oneOnOne, если сравнивать
        // было нечего» — «сравнивались» здесь про этот кластер (эмбеддинг есть) и про вход в
        // целом (`profiles` непуст), не про исход сравнения.
        let compared = speaker.embedding != nil && !input.profiles.isEmpty
        return SpeakerAssignment(
            cluster: speaker.cluster, personId: nil, confidence: 0.0,
            source: compared ? .voiceProfile : .oneOnOne, runnerUp: nil
        )
    }

    /// Правило 2. Сравнивает эмбеддинг кластера только с `profiles` (уже все нужной версии —
    /// инв. 3 проверен раньше, в `validateStructure`). Разной длины при совпавшей версии —
    /// инв. 17, `embeddingModelMismatch`.
    private func matchVoiceProfile(
        speaker: Transcript.Speaker,
        profiles: [SpeakerProfile],
        thresholds: AttributionThresholds
    ) throws -> SpeakerAssignment? {
        guard let embedding = speaker.embedding, !profiles.isEmpty else { return nil }

        let similarities = try profiles.map { profile -> (profile: SpeakerProfile, similarity: Double) in
            guard embedding.count == profile.embedding.count else {
                throw AttributionError.embeddingModelMismatch(
                    expected: profile.modelVersion, actual: profile.modelVersion
                )
            }
            return (profile, cosineSimilarity(embedding, profile.embedding))
        }.sorted { $0.similarity > $1.similarity }

        guard let best = similarities.first else { return nil }
        let second = similarities.count > 1 ? similarities[1] : nil
        let margin = best.similarity - (second?.similarity ?? -Double.infinity)
        guard best.similarity >= thresholds.profileMatchMin, margin >= thresholds.profileMatchMargin else {
            return nil
        }
        let runnerUp = second.map {
            SpeakerAssignment.Candidate(personId: $0.profile.personId, similarity: $0.similarity)
        }
        return SpeakerAssignment(
            cluster: speaker.cluster, personId: best.profile.personId,
            confidence: best.similarity, source: .voiceProfile, runnerUp: runnerUp
        )
    }

    /// Правило 3: `attendees` — ровно двое, один из них `me`, системный кластер во всём
    /// транскрипте ровно один.
    private func matchOneOnOne(
        speaker: Transcript.Speaker,
        attendees: [PersonRecord],
        me: PersonRecord?,
        systemClusterCount: Int
    ) -> SpeakerAssignment? {
        guard systemClusterCount == 1, attendees.count == 2, let me,
              attendees.contains(where: { $0.id == me.id }),
              let other = attendees.first(where: { $0.id != me.id }) else {
            return nil
        }
        return SpeakerAssignment(
            cluster: speaker.cluster, personId: other.id, confidence: 0.95, source: .oneOnOne, runnerUp: nil
        )
    }
}
