//  SpeechOnset — начало энергии в куске: метка первого слова куска (module-map v1.23, «Метка первого
//  слова куска»; IR-157, MEE-513).
//
//  Модуль: gigaam · Владелец: DEV-2 · Слой: движок
//
//  sherpa-onnx ставит первому токену куска кадр 0, где бы в куске ни начиналась речь (Z6: 137 из 137
//  швов; тишина 0…1000 мс перед речью — метка первого токена всегда 0, второго — точная). Эта чистая
//  функция по PCM куска (16 кГц, моно, Float32 — ровно то, что получил распознаватель) находит, где
//  начинается сигнал, а `TokenAssembler` ставит найденное вместо метки первого токена.
//
//  Правило: окна по 20 мс (320 отсчётов) без перекрытия, RMS окна = √(среднее x²). Рассматриваются окна,
//  которые начинаются раньше метки второго токена, не являющегося знаком препинания (токен один — весь
//  кусок; последнее окно куска может быть короче 20 мс). Порог = max(0,003; 0,1 · наибольший RMS среди
//  рассматриваемых окон). Результат — начало первого окна с RMS ≥ порога; раз окно начинается раньше
//  метки второго токена, результат строго меньше неё. Порога не достигло ни одно окно — `nil`: метка
//  остаётся такой, какую отдал распознаватель.
//
//  Константы — модуля, не настройка профиля; порог выбран архитектором без замера на живой речи с шумом.
//  Менять их — через `interface-request`, не подбором.

enum SpeechOnset {

    /// Длина окна, мс.
    static let windowMs = 20
    /// Нижняя граница порога RMS: кусок тише — токен выдан по тишине, метка модели остаётся.
    static let absoluteThreshold: Float = 0.003
    /// Доля наибольшего RMS среди рассматриваемых окон.
    static let relativeThreshold: Float = 0.1
    /// Частота PCM куска, Гц (та же, что у `ChunkCutter`).
    static let sampleRate = 16_000

    /// Отсчётов в окне.
    static var windowSamples: Int { sampleRate * windowMs / 1_000 }

    /// Начало энергии в куске, мс от начала куска.
    ///
    /// - Parameters:
    ///   - samples: PCM куска, 16 кГц, моно.
    ///   - secondTokenMs: метка второго токена куска, не являющегося знаком препинания, мс от начала куска;
    ///     `nil` — токен один, рассматривается весь кусок.
    /// - Returns: начало первого окна с RMS ≥ порога, строго меньше `secondTokenMs`; `nil` — ни одно окно
    ///   порога не достигло (или окон нет).
    static func speechOnsetMs(samples: [Float], secondTokenMs: Int?) -> Int? {
        let rms = windowRMS(samples, beforeMs: secondTokenMs)
        guard let loudest = rms.max() else { return nil }
        let threshold = max(absoluteThreshold, relativeThreshold * loudest)
        guard let index = rms.firstIndex(where: { $0 >= threshold }) else { return nil }
        return index * windowMs
    }

    /// RMS окон, начинающихся раньше `beforeMs` (`nil` — все окна куска).
    private static func windowRMS(_ samples: [Float], beforeMs: Int?) -> [Float] {
        let size = windowSamples
        var count = (samples.count + size - 1) / size
        if let beforeMs {
            // окно `index` начинается в `index · windowMs`; нужны те, у кого начало < beforeMs
            count = min(count, max(0, (beforeMs + windowMs - 1) / windowMs))
        }
        return (0..<count).map { index in
            let lower = index * size
            let upper = min(lower + size, samples.count)
            var sum: Float = 0
            for position in lower..<upper {
                sum += samples[position] * samples[position]
            }
            return (sum / Float(upper - lower)).squareRoot()
        }
    }
}
