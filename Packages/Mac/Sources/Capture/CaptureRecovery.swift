//  CaptureRecovery — `recover(directory:)`, C-004 §«Восстановление оборванной записи»,
//  инвариант 18.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Не трогает состояние идущего сеанса: восстановление читает файлы с диска независимо от
//  `phase` (контракт предполагает вызов при старте процесса, до всякого `start()`, — `SessionCoordinator`
//  зовёт `recover` для каждой незавершённой записи из `RecordingRepository.unfinalized()`).

import DomainCore
import Foundation

extension AudioCaptureImpl {

    public func recover(directory: URL) async throws -> RecordingManifest {
        do {
            let manifest = try ManifestWriter.read(from: directory)
            if manifest.endedAt != nil {
                return manifest
            }
            guard let reference = manifest.tracks.first(where: { $0.channel == .mic })
                ?? manifest.tracks.first(where: { $0.channel == .system }) else {
                throw CaptureError.recoveryFailed(directoryName: directory.lastPathComponent,
                                                  message: "манифест без единого трека")
            }
            let frames = TrackFile.framesOnDisk(at: directory.appendingPathComponent(reference.fileName),
                                                channelCount: reference.channelCount)
            let durationSeconds = Double(frames) / Double(reference.sampleRate)
            let endedAt = manifest.startedAt.addingTimeInterval(durationSeconds)
            let atMs = Int((durationSeconds * 1000).rounded())
            // `gapMs` здесь — не измерение (измерить нечем: данные после последнего `flush()`
            // до SIGKILL на диск не попали и не оставили ни байта, по которому их длительность
            // можно было бы прочесть постфактум), а верхняя граница из инварианта 26: реализация
            // сбрасывает буферы на диск не реже `truncatedTailBudgetMs`, значит обрезанный хвост
            // не может превышать эту величину. Возврат MEE-317 (24.09), К27(б): харнесс-писатель
            // (`CaptureManualHarness.writeChunksForever`) теперь сбрасывает с той же частотой —
            // не после каждой порции, — так что и его собственный необрезанный хвост не превышает
            // тот же бюджет: граница здесь и реальный сценарий писателя согласованы.
            let discontinuity = try RecordingManifest.Discontinuity(
                atMs: atMs, gapMs: AudioCaptureLimits.truncatedTailBudgetMs,
                scaleErrorMs: ScaleError.compute(reason: .truncated, fileMinusHostMs: nil), reason: .truncated
            )
            let marker = try RecordingManifest.Marker(kind: .discontinuity, atMs: atMs, detail: "recover")
            let recovered = try RecordingManifest(
                schemaVersion: manifest.schemaVersion, recordingId: manifest.recordingId,
                meetingId: manifest.meetingId, directoryName: manifest.directoryName,
                startedAt: manifest.startedAt, endedAt: endedAt, tracks: manifest.tracks,
                markers: manifest.markers + [marker], capturedProcesses: manifest.capturedProcesses,
                captureGroupKey: manifest.captureGroupKey, inputDevices: manifest.inputDevices,
                discontinuities: manifest.discontinuities + [discontinuity], isFinalized: false
            )
            try ManifestWriter.writeAtomically(recovered, to: directory)
            return recovered
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.recoveryFailed(directoryName: directory.lastPathComponent, message: "\(error)")
        }
    }
}
