//  ChunkCutter — выбор места разреза записи на куски 20–30 с (IR-152, module-map «Нарезка длинной записи»).
//
//  Модуль: gigaam · Владелец: DEV-2 · Слой: движок
//
//  Чистая функция без ввода-вывода. Экспорт модели принимает не более ~200 с, а память растёт
//  квадратично, поэтому запись режется на куски. VAD не используется и перекрытия нет: разрез
//  приходится на самую тихую точку окна [20 с; 30 с], а не на слово.

enum ChunkCutter {

    /// Частота дискретизации входа — PCM 16 кГц моно (порт `GigaAMAudioSource`).
    static let sampleRate = 16_000
    /// Максимум куска, мс.
    static let maxChunkMs = 30_000
    /// Минимум не последнего куска, мс.
    static let minChunkMs = 20_000
    /// Окно скользящего RMS, мс.
    static let rmsWindowMs = 200
    /// Шаг скользящего RMS, мс.
    static let rmsStepMs = 20

    /// Отсчётов в миллисекундах: 16 отсчётов на мс, все константы модуля кратны 20 мс = 320 отсчётам.
    static func samples(ms: Int) -> Int {
        ms * sampleRate / 1_000
    }

    /// Длина следующего куска в отсчётах.
    ///
    /// - Parameters:
    ///   - window: до 30 с записи от текущей позиции (лишнее за 30 с игнорируется).
    ///   - isLast: окно дочитано до конца записи.
    /// - Returns: `window.count`, если окно короче 30 с или последнее; иначе длина в [20 с; 30 с],
    ///   кратная 320 отсчётам. При цифровой тишине во всём окне разреза — ровно 30 с.
    static func cutLength(window: [Float], isLast: Bool) -> Int {
        let maxSamples = samples(ms: maxChunkMs)
        if window.count < maxSamples || (isLast && window.count == maxSamples) {
            return window.count
        }
        let rmsSize = samples(ms: rmsWindowMs)
        let step = samples(ms: rmsStepMs)
        var bestStart = samples(ms: minChunkMs)
        var bestEnergy = Double.infinity
        var start = bestStart
        while start + rmsSize <= maxSamples {
            let energy = sumOfSquares(window, from: start, count: rmsSize)
            // `<=`: при равенстве энергии выигрывает более позднее окно.
            if energy <= bestEnergy {
                bestEnergy = energy
                bestStart = start
            }
            start += step
        }
        guard bestEnergy > 0 || hasSignal(window, from: samples(ms: minChunkMs), to: maxSamples) else {
            return maxSamples
        }
        return bestStart + rmsSize / 2
    }

    /// Сумма квадратов — RMS монотонен по ней, корень при сравнении не нужен.
    private static func sumOfSquares(_ window: [Float], from start: Int, count: Int) -> Double {
        var total = 0.0
        for position in start..<(start + count) {
            let value = Double(window[position])
            total += value * value
        }
        return total
    }

    private static func hasSignal(_ window: [Float], from start: Int, to end: Int) -> Bool {
        window[start..<end].contains { $0 != 0 }
    }
}
