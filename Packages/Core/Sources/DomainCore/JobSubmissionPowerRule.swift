//  Правило §4 C-013 «обрабатывать только от сети» — одно определение для всех, кто ставит
//  задачи: цепочка `SessionMachine.submitChain` и `AppFacadeImpl.retranscribe` (MEE-464,
//  бэклог приёмки MEE-420). Раньше тело было записано дважды дословно.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Расширение внутреннее (`internal`): публичная поверхность `domain-core` не растёт.

import Foundation

extension JobSubmission {

    /// Подача с правилом §4 C-013: при `processOnACPowerOnly == true` поднимает
    /// `requiresACPower` ПРИ ПОСТАНОВКЕ задачи; иначе (или если условие уже поднято)
    /// возвращает подачу без изменений, поле в поле.
    func applyingPowerRule(_ settings: AppSettings) -> JobSubmission {
        guard settings.processOnACPowerOnly, !conditions.requiresACPower else { return self }
        return JobSubmission(
            payload: payload, priority: priority, maxAttempts: maxAttempts,
            runAfter: runAfter,
            conditions: JobConditions(
                requiresACPower: true,
                forbidWhileRecording: conditions.forbidWhileRecording,
                maxThermalPressure: conditions.maxThermalPressure,
                requiresProfileReady: conditions.requiresProfileReady
            ),
            dedupKey: dedupKey
        )
    }
}
