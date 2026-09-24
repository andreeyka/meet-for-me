//  CaptureManifest — сборка `RecordingManifest` из состояния сеанса и атомическая запись.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Атомарность (инвариант 18, идемпотентность `recover`, и требование C-002 «пишется
//  атомарно») — запись во временный файл того же каталога и `rename(2)`: на той же файловой
//  системе rename атомарен, а конкурентный читатель либо не видит файла вовсе, либо видит его
//  целиком — промежуточного состояния нет.

import DomainCore
import Foundation

/// `package`, не `public` — та же точка входа, что использует харнесс-писатель (К27б, план
/// MEE-315 §6) для записи `manifest.json` тем же путём, каким его пишет реализация: второй
/// источник истины дублированием этого кода во втором месте был бы дороже.
package enum ManifestWriter {

    package static func writeAtomically(_ manifest: RecordingManifest, to directory: URL) throws {
        let bytes = try DomainJSON.encode(manifest)
        let destination = directory.appendingPathComponent("manifest.json")
        let temporary = directory.appendingPathComponent(".manifest.json.\(UUID().uuidString).tmp")
        try bytes.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }

    static func read(from directory: URL) throws -> RecordingManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try DomainJSON.decode(RecordingManifest.self, from: data)
    }
}

extension AudioCaptureImpl {

    func buildManifest(_ session: CaptureSessionState, endedAt: Date?, isFinalized: Bool) throws -> RecordingManifest {
        try RecordingManifest(
            recordingId: session.recordingId,
            meetingId: session.meetingId,
            directoryName: session.recordingId.uuidString,
            startedAt: session.startedAt,
            endedAt: endedAt,
            tracks: try session.manifestTracks(),
            markers: session.markers,
            capturedProcesses: Array(session.capturedProcesses.values).sorted { $0.pid < $1.pid },
            captureGroupKey: session.captureGroupKey,
            inputDevices: session.inputDevices,
            discontinuities: session.discontinuities,
            isFinalized: isFinalized
        )
    }

    /// Пишет манифест по текущему состоянию сеанса. Отказ записи не переводит сеанс дальше —
    /// он превращается в `systemUnavailable` там, где вызывающая сторона уже кидает.
    @discardableResult
    func writeManifest(_ session: CaptureSessionState, endedAt: Date?, isFinalized: Bool) -> Bool {
        guard let manifest = try? buildManifest(session, endedAt: endedAt, isFinalized: isFinalized)
        else { return false }
        guard (try? ManifestWriter.writeAtomically(manifest, to: session.directory)) != nil else { return false }
        return true
    }
}
