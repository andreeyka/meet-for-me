//  DiarizeJobHandler — обработчик-пустышка задачи `.diarize` (C-012 v11, решение IR-145
//  MEE-469, п. 4; C-018 §8.7). Цепочка `transcode → transcribe → diarize → attribute`
//  ставит `diarize`, а без зарегистрированного обработчика задача не «готова к запуску»
//  (C-013), и `attribute` не наступит.
//
//  Диаризации в Срезе 1 нет (C-012 инв. 26): исполнить нечем, слить нечем. `run` возвращает
//  `.success`, не обращаясь ни к одному порту.
//
//  ЦЕНА, названная решением: в журнале появляется `succeeded` задачи, которая ничего не
//  сделала. Пустышка получит тело, когда придёт диаризация; цепочка при этом не изменится.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

public struct DiarizeJobHandler: JobHandler {
    public let type: JobType = .diarize

    public init() {}

    public func run(
        _ job: Job,
        progress: @Sendable @escaping (Double) -> Void
    ) async -> JobOutcome {
        .success
    }
}
