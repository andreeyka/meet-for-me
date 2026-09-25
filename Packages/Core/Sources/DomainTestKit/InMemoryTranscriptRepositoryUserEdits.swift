//  InMemoryTranscriptRepository.markSegmentsUserEdited — C-010 v25, инвариант 34
//  (IR-135, MEE-421). Разведено в отдельный файл по объёму (`file_length`), не по
//  смыслу: `InMemoryTranscriptRepository.swift` с этим методом внутри перерастал
//  предел SwiftLint (400 строк) — тот же приём, что `InMemoryTranscriptRepositoryCorrections.swift`.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)

import DomainCore

extension InMemoryTranscriptRepository {

    /// Ставит `isUserEdited = true`, ничего другого не трогает. Пустой список — ничего
    /// не делает. Чужой id — `constraintViolation`, атомарно: существование всех id
    /// проверяется ДО первой записи; повтор id в списке безвреден (`Set`).
    public func markSegmentsUserEdited(segmentIds: [Int64]) async throws {
        log.record(
            port: Self.portName, method: "markSegmentsUserEdited(segmentIds:)",
            arguments: segmentIds.map(String.init)
        )
        guard !segmentIds.isEmpty else { return }
        if let error = failureIfAny(.markSegmentsUserEdited, id: nil) {
            throw error
        }
        let missing = locked { () -> Int64? in
            let uniqueIds = Set(segmentIds)
            if let absent = uniqueIds.first(where: { !segmentExists($0) }) {
                return absent
            }
            for segmentId in uniqueIds {
                setUserEdited(segmentId)
            }
            return nil
        }
        if let missing {
            throw StorageError.constraintViolation(message: "markSegmentsUserEdited: сегмент \(missing) не найден")
        }
    }

    /// Зовётся под замком.
    private func segmentExists(_ segmentId: Int64) -> Bool {
        rowsByTranscript.values.contains { rows in rows.contains { $0.id == segmentId } }
    }

    /// Зовётся под замком.
    private func setUserEdited(_ segmentId: Int64) {
        for (transcriptId, rows) in rowsByTranscript {
            guard let index = rows.firstIndex(where: { $0.id == segmentId }) else { continue }
            let row = rows[index]
            rowsByTranscript[transcriptId]?[index] = SegmentRow(
                id: row.id, transcriptId: row.transcriptId, segment: row.segment,
                personId: row.personId, speakerConfidence: row.speakerConfidence,
                attributionSource: row.attributionSource, isUserEdited: true
            )
            return
        }
    }
}
