//  GigaAMRecognizer — порт распознавателя: «PCM 16 кГц моно Float32 → токены с метками кадров».
//
//  Модуль: gigaam · Владелец: DEV-2 · Слой: движок
//
//  Ядро модуля (нарезка, сшивка, сегменты, ошибки) живёт в `Packages/Core` и собирается на Linux;
//  реализацию поверх sherpa-onnx даёт таргет `GigaAMSherpa` в `Packages/Mac` (MEE-503). Здесь
//  ни одной зависимости от рантайма инференса.

import Foundation

/// Результат распознавания одного куска записи.
public struct RecognizedChunk: Equatable, Sendable {
    /// Текст куска целиком.
    public let text: String
    /// Токены; начало слова помечено `▁`.
    public let tokens: [String]
    /// Метки токенов в секундах от начала куска; `timestamps.count == tokens.count`.
    public let timestamps: [Double]

    public init(text: String, tokens: [String], timestamps: [Double]) {
        self.text = text
        self.tokens = tokens
        self.timestamps = timestamps
    }
}

/// Распознаватель одного куска. Вызывающий подаёт не более 30 с (инвариант 19 C-011);
/// на бо́льшем входе реализация вправе бросить.
public protocol GigaAMRecognizer: Sendable {
    /// - Parameter samples: PCM 16 кГц, моно, Float32.
    func recognize(samples: [Float]) throws -> RecognizedChunk
}

/// Отказ адаптера, который движок сводит к `EngineError`.
public enum GigaAMRecognizerError: Error, Equatable, Sendable {
    /// В каталоге модели нет `model.int8.onnx` или `tokens.txt` — движок отвечает `modelMissing`.
    case modelFilesMissing
    /// Модель не загрузилась или вызов рантайма упал — движок отвечает `runtimeFailure`.
    case runtimeFailure(message: String)
}

/// Фабрика распознавателя по каталогу модели (`model.int8.onnx` и `tokens.txt`).
///
/// Ядро её не реализует: реализацию поставляет адаптер `GigaAMSherpa`, движок получает её снаружи.
public protocol GigaAMRecognizerFactory: Sendable {
    func makeRecognizer(modelDirectory: URL) throws -> any GigaAMRecognizer
}
