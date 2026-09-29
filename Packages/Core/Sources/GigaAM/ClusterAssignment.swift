//  ClusterAssignment — кластер системного канала без диаризации (C-011 инвариант 18, IR-149).
//
//  Модуль: gigaam · Владелец: DEV-2 · Слой: движок
//
//  `transcribe` не диаризует: у каждого содержательного сегмента `.system` кластер `0`, у пустого
//  `.system` и у любого `.mic` — `nil` (C-003, инварианты 5 и 6). Если кластер получил хотя бы один
//  сегмент, `speakers` — ровно один `Speaker(0, nil, nil, S)`, где `S` — сумма длительностей этих
//  сегментов; иначе `speakers == []`.

import DomainCore
import Foundation

enum ClusterAssignment {

    /// Кластер, который получает системный канал без диаризации.
    static let systemCluster = 0

    struct Result: Equatable {
        /// Кластер каждого сегмента в порядке входа.
        let clusters: [Int?]
        let speakers: [Transcript.Speaker]
    }

    static func assign(_ segments: [SegmentDraft]) throws -> Result {
        var totalMs = 0
        var clusters: [Int?] = []
        for segment in segments {
            if segment.channel == .system, hasContent(segment.text) {
                clusters.append(systemCluster)
                totalMs += segment.endMs - segment.startMs
            } else {
                clusters.append(nil)
            }
        }
        guard clusters.contains(where: { $0 != nil }) else {
            return Result(clusters: clusters, speakers: [])
        }
        let speaker = try Transcript.Speaker(
            cluster: systemCluster, embedding: nil, embeddingModelVersion: nil, totalMs: totalMs
        )
        return Result(clusters: clusters, speakers: [speaker])
    }

    /// Содержательный — не пустой после обрезки пробелов (как в инварианте 6 C-003).
    private static func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
