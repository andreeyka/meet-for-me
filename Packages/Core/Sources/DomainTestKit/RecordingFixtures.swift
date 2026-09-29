//  RecordingFixtures — записи и манифесты для C-012 v12 §1.1 (MEE-480): дорожки `pcm-caf`
//  48 000 Гц, как их пишет `capture` в срезе 1, и `isFinalized == false` у каждой записи
//  (C-013 v16, «Поведение»: перекодирования в срезе нет).
//
//  Здесь, а не в `EngineXPCClientTests`, — MEE-495, п. 2: тот же манифест отдаёт
//  `AnyIdFinalizedRecordingRepository`, и раньше он был повторён там вручную. Источник один.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фикстуры для тестов)

import Foundation
import DomainCore

public enum RecordingFixtures {

    public static func systemTrack() throws -> RecordingManifest.Track {
        try RecordingManifest.Track(
            channel: .system, fileName: "audio-system.caf", sampleRate: 48_000, channelCount: 2, format: "pcm-caf"
        )
    }

    public static func micTrack() throws -> RecordingManifest.Track {
        try RecordingManifest.Track(
            channel: .mic, fileName: "audio-mic.caf", sampleRate: 48_000, channelCount: 1, format: "pcm-caf"
        )
    }

    /// Манифест с заданными дорожками в заданном порядке; `isFinalized` — как скажет тест
    /// (по умолчанию `false`, штатное состояние среза 1).
    public static func manifest(
        recordingId: UUID, tracks: [RecordingManifest.Track], isFinalized: Bool = false
    ) throws -> RecordingManifest {
        let startedAt = Date(timeIntervalSince1970: 1_789_113_600)
        let hasMic = tracks.contains { $0.channel == .mic }
        let micSpan = try RecordingManifest.InputDeviceSpan(
            atMs: 0, present: true, name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice"
        )
        return try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(600),
            tracks: tracks, markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: hasMic ? [micSpan] : [], discontinuities: [], isFinalized: isFinalized
        )
    }

    /// Запись по умолчанию: две дорожки в порядке `[system, mic]`.
    public static func record(
        recordingId: UUID, status: RecordingStatus = .finalized, tracks: [RecordingManifest.Track]? = nil
    ) throws -> RecordingRecord {
        let resolved = try tracks ?? [systemTrack(), micTrack()]
        return RecordingRecord(manifest: try manifest(recordingId: recordingId, tracks: resolved), status: status)
    }
}
