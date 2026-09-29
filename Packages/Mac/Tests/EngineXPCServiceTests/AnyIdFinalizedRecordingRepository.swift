//  AnyIdFinalizedRecordingRepository — MEE-480: с C-012 v12 §1.1 `EngineXPCClient` читает запись
//  из `RecordingRepository` раньше каталога моделей. Тестам этой цели запись безразлична (они
//  проверяют сервис и провод), поэтому на любой `recording(id:)` отдаётся пригодная запись
//  (`.finalized`, дорожки `system` и `mic`, `pcm-caf`) с этим `id`. Поведение по записи
//  проверяет `EngineXPCClientTests/EngineXPCClientRecordingTests*`. Продублировано из той цели
//  по той же причине, что `PlistSurgery`: тестовые цели друг друга не импортируют.
//
//  Модуль: engine-xpc (тесты) · Владелец: DEV-2

import Foundation
import DomainCore

final class AnyIdFinalizedRecordingRepository: RecordingRepository, @unchecked Sendable {

    func recording(id: UUID) async throws -> RecordingRecord? {
        let startedAt = Date(timeIntervalSince1970: 1_789_113_600)
        let manifest = try RecordingManifest(
            recordingId: id, meetingId: nil, directoryName: id.uuidString,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(600),
            tracks: [
                try RecordingManifest.Track(
                    channel: .system, fileName: "audio-system.caf", sampleRate: 48_000,
                    channelCount: 2, format: "pcm-caf"
                ),
                try RecordingManifest.Track(
                    channel: .mic, fileName: "audio-mic.caf", sampleRate: 48_000, channelCount: 1, format: "pcm-caf"
                )
            ],
            markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: [
                try RecordingManifest.InputDeviceSpan(
                    atMs: 0, present: true, name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice"
                )
            ],
            discontinuities: [], isFinalized: false
        )
        return RecordingRecord(manifest: manifest, status: .finalized)
    }

    func save(_ record: RecordingRecord) async throws {}
    func recordings(meetingId: UUID) async throws -> [RecordingRecord] { [] }
    func unfinalized() async throws -> [RecordingRecord] { [] }
    func adHoc() async throws -> [RecordingRecord] { [] }
    func delete(recordingId: UUID, deleteFiles: Bool) async throws {}
    func createDirectory(recordingId: UUID) async throws -> URL {
        URL(fileURLWithPath: "/dev/null").appendingPathComponent(recordingId.uuidString)
    }
}
