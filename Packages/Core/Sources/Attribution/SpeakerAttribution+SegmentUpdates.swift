//  SpeakerAttribution+SegmentUpdates — C-015 §5 правило 1 (микрофонный канал) и инв. 22
//  (какая единица едет в `segmentUpdates`, независимо от канала).

import DomainCore

extension SpeakerAttribution {
    /// Инв. 8/21в: сегмент из `input.userEditedSegmentIds` не едет сюда ни при каком канале —
    /// проверено раньше состава каждой ветки. Инв. 21б: значения `.mic` — правило 1. Инв. 22б:
    /// значения системного сегмента с кластером — значения его назначения, кроме исключения
    /// инв. 16. Системный сегмент без кластера (пустой после отсечения пробелов, C-003 инв. 6)
    /// не определяет ничего — граница инв. 22, элемента для него нет.
    func computeSegmentUpdates(
        input: AttributionInput,
        assignments: [SpeakerAssignment],
        textCorrections: [TextCorrection]
    ) -> [SegmentAttributionUpdate] {
        let assignmentByCluster = Dictionary(uniqueKeysWithValues: assignments.map { ($0.cluster, $0) })
        let correctedSegmentIds = Set(textCorrections.map(\.segmentId))
        let userEditedSegmentIds = Set(input.userEditedSegmentIds)

        var updates: [SegmentAttributionUpdate] = []
        for (index, segment) in input.transcript.segments.enumerated() {
            let segmentId = input.segmentIds[index]
            guard !userEditedSegmentIds.contains(segmentId) else { continue }

            if segment.channel == .mic {
                updates.append(micChannelUpdate(segmentId: segmentId, me: input.me))
                continue
            }

            guard let cluster = segment.speakerCluster, let assignment = assignmentByCluster[cluster] else { continue }
            updates.append(systemSegmentUpdate(
                segmentId: segmentId, assignment: assignment, wasCorrected: correctedSegmentIds.contains(segmentId)
            ))
        }
        return updates
    }

    /// Правило 1, дословно: `personId == me?.id`, `1.0`/`me != nil`, иначе `nil`/`0.0`;
    /// `source` всегда `.micChannel` — не вытесняется постправкой ни при каком `me` (инв. 16).
    private func micChannelUpdate(segmentId: Int64, me: PersonRecord?) -> SegmentAttributionUpdate {
        SegmentAttributionUpdate(
            segmentId: segmentId, personId: me?.id,
            speakerConfidence: me != nil ? 1.0 : 0.0, attributionSource: .micChannel
        )
    }

    /// Инв. 16: замена текста есть, а кластер не опознан ни одним из правил 2–4 (`personId ==
    /// nil` и источник не `.user` — `.user` приходит только от `confirm`/`reject`, решение
    /// человека, не «правило не опознало») → `attributionSource == .nameDictionary`, значения
    /// `personId`/`speakerConfidence` — те, что у назначения (инв. 22б, «исключение чужое»).
    private func systemSegmentUpdate(
        segmentId: Int64,
        assignment: SpeakerAssignment,
        wasCorrected: Bool
    ) -> SegmentAttributionUpdate {
        let unassignedByRules = assignment.personId == nil && assignment.source != .user
        let attributionSource: AttributionSource = (wasCorrected && unassignedByRules)
            ? .nameDictionary
            : assignment.source
        return SegmentAttributionUpdate(
            segmentId: segmentId, personId: assignment.personId,
            speakerConfidence: assignment.confidence, attributionSource: attributionSource
        )
    }
}
