//  SpeakerAttribution — реализация AttributionPort, C-015 (MEE-23) v9, §2–6: правила
//  назначения 1–4, постправка словарём имён (§6), confirm/reject (инв. 7-12). Обработчик
//  задачи attribute и AppFacade (§7) — не эта задача (MEE-406, «Не в этой задаче»).
//
//  Модуль: attribution · Владелец: DEV-2 · Слой: домен
//
//  Структура, не класс: «AttributionPort — Sendable; реализация не имеет изменяемого
//  состояния между вызовами» («Поведение», C-015). Логика разнесена по расширениям в
//  соседних файлах (Validation/Assignments/Similarity/TextCorrections/SegmentUpdates/
//  ProfileUpdate) — тем же приёмом, что уже стоит в дереве (type_body_length).

import DomainCore
import Foundation

public struct SpeakerAttribution: AttributionPort, Sendable {
    public init() {}

    public func attribute(
        _ input: AttributionInput,
        thresholds: AttributionThresholds
    ) async throws -> AttributionResult {
        try compute(input: input, thresholds: thresholds, override: nil)
    }

    public func confirm(
        transcriptId: UUID,
        cluster: Int,
        personId: UUID,
        input: AttributionInput
    ) async throws -> AttributionResult {
        try validateKnownPerson(personId, input: input)
        try validateKnownCluster(cluster, input: input)
        let override = SpeakerAssignment(
            cluster: cluster, personId: personId, confidence: 1.0, source: .user, runnerUp: nil
        )
        let base = try compute(input: input, thresholds: .slice1Defaults, override: override)
        return AttributionResult(
            transcriptId: transcriptId,
            assignments: base.assignments,
            segmentUpdates: base.segmentUpdates,
            textCorrections: base.textCorrections,
            profileUpdates: confirmedProfileUpdates(cluster: cluster, personId: personId, input: input)
        )
    }

    public func reject(
        transcriptId: UUID,
        cluster: Int,
        input: AttributionInput
    ) async throws -> AttributionResult {
        try validateKnownCluster(cluster, input: input)
        let override = SpeakerAssignment(cluster: cluster, personId: nil, confidence: 0.0, source: .user, runnerUp: nil)
        let base = try compute(input: input, thresholds: .slice1Defaults, override: override)
        return AttributionResult(
            transcriptId: transcriptId,
            assignments: base.assignments,
            segmentUpdates: base.segmentUpdates,
            textCorrections: base.textCorrections,
            profileUpdates: []
        )
    }

    /// Общий проход для всех трёх методов порта (инв. 4 не сужен текстом контракта до
    /// одного метода — `confirm`/`reject` тоже отдают полный `assignments`/`segmentUpdates`,
    /// с одним кластером, подменённым решением пользователя, а не только его строкой).
    /// `override` задаёт `.user`-решение для одного кластера — остальные считаются
    /// правилами 2–4, как в `attribute`. `confirm`/`reject` не принимают `thresholds`
    /// (К35) — для чужих, не подменённых кластеров используется `.slice1Defaults`,
    /// единственное значение порогов, живущее в Срезе 1 (C-015 §7, «Пороги»).
    func compute(
        input: AttributionInput,
        thresholds: AttributionThresholds,
        override: SpeakerAssignment?
    ) throws -> AttributionResult {
        try validateStructure(input: input)
        let assignments = try computeAssignments(input: input, thresholds: thresholds, override: override)
        let textCorrections = computeTextCorrections(input: input, thresholds: thresholds)
        let segmentUpdates = computeSegmentUpdates(
            input: input, assignments: assignments, textCorrections: textCorrections
        )
        return AttributionResult(
            transcriptId: input.transcriptId,
            assignments: assignments,
            segmentUpdates: segmentUpdates,
            textCorrections: textCorrections,
            profileUpdates: []
        )
    }
}
