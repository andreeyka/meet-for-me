//  AudioCaptureImpl+Buffers — приём PCM с шва, запись на диск, сброс не реже бюджета хвоста.
//  Инварианты 7, 20, 26.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API

import DomainCore
import Foundation

extension AudioCaptureImpl {

    /// Зовётся швом на своей очереди — может быть любой поток. Держит `lock` только на снятие
    /// сеанса и статуса паузы, сама запись идёт без замка (треки сами `@unchecked Sendable`,
    /// но не разделяются конкурентно: `buildAggregate` отдаёт `onBuffer`, который HAL зовёт
    /// последовательно, одним потоком за раз — то же допущение, что у `IOContext` спайка).
    func handleBuffer(_ buffer: HardwareBuffer) {
        guard case .running(let session) = currentPhase() else { return }
        if session.hostOrigin == 0 { session.hostOrigin = buffer.hostTime }
        guard !session.isPaused else { return }
        if let pending = session.pendingRebuild {
            resolveRebuild(session, pending: pending, firstBufferHostTime: buffer.hostTime)
        }
        guard let track = session.track(for: buffer.slot) else { return }
        let adapted = ChannelAdapter.adapt(buffer.samples, frameCount: buffer.frameCount,
                                           from: buffer.channelCount, to: track.channelCount)
        try? track.append(adapted)
        maybeFlush(session, track: track, hostTime: buffer.hostTime)
        updateLevels(session, slot: buffer.slot, samples: buffer.samples)
    }

    /// Инвариант 23: `.levels`, частота ≤10 Гц. Возврат MEE-317 (второй круг): троттлинг — по
    /// МЕТКЕ ВРЕМЕНИ ДОСТАВКИ буфера порту (часы вызова, `now()` — шов, по умолчанию `Date()`,
    /// возврат РП по MEE-377 24.09), не по `hostTime` данных (как `maybeFlush`, инвариант 26) —
    /// тот приём здесь был ошибкой: `.levels` кормит
    /// индикатор для человека (C-016), а не позицию на диске, и обязан не превышать 10
    /// событий в РЕАЛЬНУЮ секунду наблюдателя. Пачка буферов, доставленная разом (устройство
    /// отдало данные одним куском), но с `hostTime` каждого буфера, разнесённым больше чем на
    /// `minimumIntervalMs` (например, буферы старого формата, оставшиеся в очереди HAL), прошла
    /// бы троттлинг по `hostTime` на каждом буфере и дала бы больше 10 событий за реальную
    /// секунду — то, что перечень и запрещает.
    private func updateLevels(_ session: CaptureSessionState, slot: HardwareBuffer.Slot, samples: [Float]) {
        let level = AudioLevel.value(fromSamples: samples)
        switch slot {
        case .mic: session.lastMicLevel = level
        case .system: session.lastSystemLevel = level
        }
        let deliveredAt = now()
        if let last = session.lastLevelsEmitAt,
           deliveredAt.timeIntervalSince(last) * 1000 < Double(AudioLevel.minimumIntervalMs) {
            return
        }
        session.lastLevelsEmitAt = deliveredAt
        emit(.levels(.init(
            mic: session.micTrack != nil ? session.lastMicLevel : nil,
            system: session.systemTrack != nil ? session.lastSystemLevel : nil
        )))
    }

    private func currentPhase() -> CapturePhase {
        lock.lock(); defer { lock.unlock() }
        return phase
    }

    /// Инвариант 26: интервал между сбросами не больше `truncatedTailBudgetMs`, пока данные
    /// поступают. Проверяется по `hostTime` буфера (миллисекунды монотонных часов — шов несёт
    /// их уже в этом виде, см. `HardwareBuffer`), а не по часам вызова: буфер несёт момент,
    /// в который данные реально пришли, вызов метода — момент, когда об этом узнал порт.
    private func maybeFlush(_ session: CaptureSessionState, track: TrackFile, hostTime: UInt64) {
        let last = track.lastFlushAt
        guard last == 0 || hostTime &- last >= UInt64(AudioCaptureLimits.truncatedTailBudgetMs) else { return }
        track.flush(atHostTime: hostTime)
    }
}

/// Значение `.levels` — инвариант 23: `max(0, min(1, (dBFS+60)/60))` от среднеквадратичной
/// амплитуды буфера. Эвристика для индикатора (C-016), не измерение громкости — контракт не
/// называет ни окно усреднения, ни взвешивание, поэтому берётся буфер целиком, тем же приёмом,
/// что и остальные адаптеры этого модуля (без скользящего окна, без дополнительного состояния).
enum AudioLevel {
    static let minimumIntervalMs = 100   // ≤10 Гц

    static func value(fromSamples samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        let dBFS = 20 * log10(rms)
        return max(0, min(1, (dBFS + 60) / 60))
    }
}

/// Приводит interleaved PCM к объявленному числу каналов — инвариант 7. Лишние каналы
/// отбрасываются, недостающие дублируют последний известный (тот же приём, что у спайка:
/// `adapted[frame*channels+channel] = scratch[frame*sessionChannels+min(channel, sessionChannels-1)]`).
enum ChannelAdapter {
    static func adapt(
        _ samples: [Float], frameCount: Int, from sourceChannels: Int, to targetChannels: Int
    ) -> [Float] {
        guard sourceChannels != targetChannels, sourceChannels > 0, targetChannels > 0 else { return samples }
        var result = [Float](repeating: 0, count: frameCount * targetChannels)
        for frame in 0..<frameCount {
            for channel in 0..<targetChannels {
                let source = min(channel, sourceChannels - 1)
                let sourceIndex = frame * sourceChannels + source
                guard sourceIndex < samples.count else { continue }
                result[frame * targetChannels + channel] = samples[sourceIndex]
            }
        }
        return result
    }
}
