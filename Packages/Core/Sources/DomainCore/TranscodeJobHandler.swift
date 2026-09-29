//  TranscodeJobHandler — обработчик-пустышка задачи `.transcode` (C-013 v16, решение IR-151
//  MEE-485, вариант (а); C-018 §8.7). Цепочка `transcode → transcribe → diarize → attribute`
//  начинается с `transcode`, а без зарегистрированного обработчика задача не «готова к
//  запуску» (C-013), и цепочка встаёт на первом звене.
//
//  Перекодирования в Срезе 1 нет: движок читает `pcm-caf` как есть (C-012 §1.1), 16 кГц
//  моно-копии делает и удаляет сам движок (C-011). `run` возвращает `.success`, не обращаясь
//  ни к одному порту, репозиторию и файлу.
//
//  ЦЕНА, названная решением: `transcode` числится в очереди и показывается меню-баром, хотя
//  ничего не делает. Пустышка получит тело, когда придёт перекодирование; цепочка при этом
//  не изменится.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

public struct TranscodeJobHandler: JobHandler {
    public let type: JobType = .transcode

    public init() {}

    public func run(
        _ job: Job,
        progress: @Sendable @escaping (Double) -> Void
    ) async -> JobOutcome {
        .success
    }
}
