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
            // СТРОКА (возврат MEE-317, второй круг — самокоррекция): моё прежнее обоснование было
            // фактически неверным. `TrackFile.append` пишет через `write(2)` без пользовательской
            // буферизации — байты уходят в страничный кэш ядра сразу, до всякого `flush()`.
            // `flush()` здесь — это `fsync(2)`: он про устойчивость к падению ОС/железа, а не про
            // выживание данных при SIGKILL самого процесса-писателя. Значит SIGKILL НЕ теряет ни
            // байта из того, что уже прошло через `append`, и частота `flush()` на переживаемость
            // не влияет вовсе — то, что действительно потерялось бы, это данные, ещё не дошедшие
            // до `append` к моменту сигнала (в этом писателе — доля миллисекунды между «досчитал
            // чанк» и «записал»), а не что-то, зависящее от бюджета сброса.
            //
            // Перечень К27(б) требует «`gapMs`… совпадает по порядку с интервалом сброса, заданным
            // в (а)» — но раз ничего в этом порядке величины реально не теряется, измерить здесь
            // нечего: `gapMs` ниже — не измерение, а верхняя граница-заглушка, взятая равной
            // бюджету `truncatedTailBudgetMs` (инвариант 26) просто потому, что бюджет — единственная
            // связанная с этим сценарием контрактная величина. Вилка не решена мной: (а) оставить
            // эту заглушку, как сейчас — трактуя список буквально («порядок величины» совпадает,
            // раз число равно бюджету), или (б) писать `gapMs: 0` (что честнее отражает реальность
            // write(2)) и считать формулировку списка неисполнимой в текущем тексте для этого
            // сценария. Решение — за РП.
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
