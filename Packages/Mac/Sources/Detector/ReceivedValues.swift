//  ReceivedValues — значения таблицы весов, принятые портом. Шов Ш5.
//
//  C-009 §5, §6: таблицу весов читает `domain-core`, порт получает ЗНАЧЕНИЯ — не байты, не файл
//  и не путь. Точка приёма одна — публичный инициализатор `MeetingDetector`, — и приём
//  однократен: второго набора у порта нет, заменить или перечитать набор после инициализации
//  нечем (Ш5 (ii), инвариант 22).
//
//  Значений четыре, а не три: три веса видов, которые публикует порт (инвариант 11), и срок
//  `signalTtlSeconds`, до истечения которого порт подтверждает держащееся состояние
//  (инвариант 24). Срок приходит той же точкой приёма — так велит шов Ш6 (ii).
//
//  Значения проверяются при приёме: вес вне `0...1` и неположительный или неконечный срок —
//  отказ, а не зажатие в диапазон. `domain-core` такую таблицу уже отверг бы; проверка здесь —
//  чтобы инвариант 11 держался и тогда, когда значения пришли не оттуда.

import DomainCore
import Foundation

/// Три вида сигнала, которые публикует порт. `calendarWindow` публикует домен, а не порт.
enum PublishedKind: CaseIterable {
    case clientRunning
    case clientAudioOutput
    case microphoneInUse

    var signalKind: MeetingSignalKind {
        switch self {
        case .clientRunning: return .clientRunning
        case .clientAudioOutput: return .clientAudioOutput
        case .microphoneInUse: return .microphoneInUse
        }
    }
}

/// Отказ при приёме значений.
enum ReceivedValuesError: Error, Equatable {
    case weightOutOfRange(MeetingSignalKind, Double)
    case nonPositiveSignalTtl(Double)
}

struct ReceivedValues: Equatable, Sendable {

    let clientRunning: Double
    let clientAudioOutput: Double
    let microphoneInUse: Double
    /// Срок актуальности сигнала, секунды.
    let signalTtlSeconds: Double

    init(clientRunning: Double, clientAudioOutput: Double, microphoneInUse: Double,
         signalTtlSeconds: Double) throws {
        for (kind, weight) in [(MeetingSignalKind.clientRunning, clientRunning),
                               (.clientAudioOutput, clientAudioOutput),
                               (.microphoneInUse, microphoneInUse)]
        where !(weight.isFinite && (0...1).contains(weight)) {
            throw ReceivedValuesError.weightOutOfRange(kind, weight)
        }
        guard signalTtlSeconds.isFinite, signalTtlSeconds > 0 else {
            throw ReceivedValuesError.nonPositiveSignalTtl(signalTtlSeconds)
        }
        self.clientRunning = clientRunning
        self.clientAudioOutput = clientAudioOutput
        self.microphoneInUse = microphoneInUse
        self.signalTtlSeconds = signalTtlSeconds
    }

    /// Вес вида из полученного набора — не из константы и не из второго источника (инвариант 11).
    func weight(for kind: PublishedKind) -> Double {
        switch kind {
        case .clientRunning: return clientRunning
        case .clientAudioOutput: return clientAudioOutput
        case .microphoneInUse: return microphoneInUse
        }
    }
}
