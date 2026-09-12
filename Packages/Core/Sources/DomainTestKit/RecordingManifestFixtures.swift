//  Фикстуры C-002 — «Фейк для тестов» RecordingManifest.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки для тестов)
//
//  Все отметки времени выровнены по целой секунде; `Date()`, `UUID()` и генераторы
//  случайных чисел здесь не вызываются.

import Foundation
import DomainCore

// swiftlint:disable force_try

/// Набор манифестов, покрывающий семь случаев раздела «Фейк для тестов» C-002.
public enum RecordingManifestFixtures {

    private static let micTrack = try! RecordingManifest.Track(
        channel: .mic, fileName: "audio-mic.m4a", sampleRate: 48_000,
        channelCount: 1, format: "aac-m4a"
    )
    private static let systemTrack = try! RecordingManifest.Track(
        channel: .system, fileName: "audio-system.m4a", sampleRate: 48_000,
        channelCount: 2, format: "aac-m4a"
    )
    private static let rawMicTrack = try! RecordingManifest.Track(
        channel: .mic, fileName: "audio-mic.caf", sampleRate: 48_000,
        channelCount: 1, format: "pcm-caf"
    )
    private static let rawSystemTrack = try! RecordingManifest.Track(
        channel: .system, fileName: "audio-system.caf", sampleRate: 48_000,
        channelCount: 2, format: "pcm-caf"
    )
    private static let zoomProcess = try! RecordingManifest.CapturedProcess(
        pid: 4821, bundleId: "us.zoom.xos", executableName: "zoom.us"
    )
    private static let builtInMicrophone = try! RecordingManifest.InputDeviceSpan(
        atMs: 0, present: true, name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice"
    )

    /// Часовая запись двух каналов без маркеров.
    public static let hourlyTwoChannels: RecordingManifest = try! make(
        identifier: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
        startedAt: 1_789_113_600,
        endedAt: 1_789_117_200,
        tracks: [micTrack, systemTrack],
        markers: [],
        captureGroupKey: "bundle:us.zoom.xos",
        inputDevices: [builtInMicrophone],
        discontinuities: [],
        isFinalized: true
    )

    /// Смена устройства посередине: маркеры `deviceChanged` и `discontinuity`, парный разрыв
    /// с `reason == .rebuild` и `scaleErrorMs >= 150`, ровно два спана с разными `uid`.
    public static let deviceChangedMidway: RecordingManifest = try! make(
        identifier: "3F2504E0-4F89-41D3-9A0C-0305E82C3302",
        startedAt: 1_789_113_600,
        endedAt: 1_789_117_200,
        tracks: [micTrack, systemTrack],
        markers: [
            try! RecordingManifest.Marker(kind: .deviceChanged, atMs: 1_800_000,
                                          detail: "BuiltInMicrophoneDevice -> A1B2C3-airpods"),
            try! RecordingManifest.Marker(kind: .discontinuity, atMs: 1_800_000,
                                          detail: "aggregate device rebuilt")
        ],
        captureGroupKey: "bundle:us.zoom.xos",
        inputDevices: [
            builtInMicrophone,
            try! RecordingManifest.InputDeviceSpan(atMs: 1_800_000, present: true,
                                                   name: "AirPods Pro", uid: "A1B2C3-airpods")
        ],
        discontinuities: [
            try! RecordingManifest.Discontinuity(atMs: 1_800_000, gapMs: 150,
                                                 scaleErrorMs: 150, reason: .rebuild)
        ],
        isFinalized: true
    )

    /// Незавершённая запись: `endedAt == nil`, `isFinalized == false`, у всех треков `pcm-caf`.
    /// Микрофона в ней не было ни разу за запись, поэтому `inputDevices` пуст.
    public static let unfinished: RecordingManifest = try! make(
        identifier: "3F2504E0-4F89-41D3-9A0C-0305E82C3303",
        startedAt: 1_789_119_000,
        endedAt: nil,
        tracks: [rawSystemTrack],
        markers: [],
        captureGroupKey: nil,
        inputDevices: [],
        discontinuities: [],
        isFinalized: false
    )

    /// Только с микрофона: один трек `.mic`, `inputDevices` непуст.
    public static let micOnly: RecordingManifest = try! make(
        identifier: "3F2504E0-4F89-41D3-9A0C-0305E82C3304",
        startedAt: 1_789_119_000,
        endedAt: 1_789_119_600,
        tracks: [rawMicTrack],
        markers: [],
        captureGroupKey: nil,
        inputDevices: [builtInMicrophone],
        discontinuities: [],
        isFinalized: false
    )

    /// Запись с усыплением ноутбука: два маркера с равным `atMs` — сортировка инварианта 8
    /// нестрогая, и это законный манифест, а не терпимость реализации.
    public static let sleepDuringRecording: RecordingManifest = try! make(
        identifier: "3F2504E0-4F89-41D3-9A0C-0305E82C3305",
        startedAt: 1_789_113_600,
        endedAt: 1_789_117_200,
        tracks: [micTrack, systemTrack],
        markers: [
            try! RecordingManifest.Marker(kind: .sleep, atMs: 1_800_000, detail: nil),
            try! RecordingManifest.Marker(kind: .discontinuity, atMs: 1_800_000, detail: nil),
            try! RecordingManifest.Marker(kind: .wake, atMs: 1_802_000, detail: nil)
        ],
        captureGroupKey: "bundle:us.zoom.xos",
        inputDevices: [builtInMicrophone],
        discontinuities: [
            try! RecordingManifest.Discontinuity(atMs: 1_800_000, gapMs: 2_000,
                                                 scaleErrorMs: 250, reason: .sleep)
        ],
        isFinalized: true
    )

    /// Запись, начатая без микрофона: первый спан говорит «устройства нет», микрофон
    /// появляется позже своим маркером `.deviceChanged`.
    public static let startedWithoutMicrophone: RecordingManifest = try! make(
        identifier: "3F2504E0-4F89-41D3-9A0C-0305E82C3306",
        startedAt: 1_789_119_000,
        endedAt: 1_789_120_800,
        tracks: [rawMicTrack, rawSystemTrack],
        markers: [
            try! RecordingManifest.Marker(kind: .deviceChanged, atMs: 900_000,
                                          detail: "нет входа -> A1B2C3-airpods")
        ],
        captureGroupKey: nil,
        inputDevices: [
            try! RecordingManifest.InputDeviceSpan(atMs: 0, present: false, name: nil, uid: nil),
            try! RecordingManifest.InputDeviceSpan(atMs: 900_000, present: true,
                                                   name: "AirPods Pro", uid: "A1B2C3-airpods")
        ],
        discontinuities: [],
        isFinalized: false
    )

    /// Оборванная запись, восстановленная производителем: `endedAt` равен `startedAt` плюс
    /// длина опорного трека, последний разрыв стоит ровно на `durationMs` с `reason == .truncated`.
    public static let truncatedRecovered: RecordingManifest = try! make(
        identifier: "3F2504E0-4F89-41D3-9A0C-0305E82C3307",
        startedAt: 1_789_119_000,
        endedAt: 1_789_120_235,
        tracks: [rawMicTrack, rawSystemTrack],
        markers: [
            try! RecordingManifest.Marker(kind: .discontinuity, atMs: 1_235_000,
                                          detail: "хвост не дошёл до диска")
        ],
        captureGroupKey: "bundle:us.zoom.xos",
        inputDevices: [builtInMicrophone],
        discontinuities: [
            try! RecordingManifest.Discontinuity(atMs: 1_235_000, gapMs: 200,
                                                 scaleErrorMs: 200, reason: .truncated)
        ],
        isFinalized: false
    )

    /// Все фикстуры набора.
    public static let allFixtures: [RecordingManifest] = [
        hourlyTwoChannels,
        deviceChangedMidway,
        unfinished,
        micOnly,
        sleepDuringRecording,
        startedWithoutMicrophone,
        truncatedRecovered
    ]

    // swiftlint:disable:next function_parameter_count
    private static func make(
        identifier: String,
        startedAt: Int,
        endedAt: Int?,
        tracks: [RecordingManifest.Track],
        markers: [RecordingManifest.Marker],
        captureGroupKey: String?,
        inputDevices: [RecordingManifest.InputDeviceSpan],
        discontinuities: [RecordingManifest.Discontinuity],
        isFinalized: Bool
    ) throws -> RecordingManifest {
        let recordingId = MeetingEventFixtures.uuid(identifier)
        return try RecordingManifest(
            recordingId: recordingId,
            meetingId: nil,
            directoryName: recordingId.uuidString,
            startedAt: Date(timeIntervalSince1970: Double(startedAt)),
            endedAt: endedAt.map { Date(timeIntervalSince1970: Double($0)) },
            tracks: tracks,
            markers: markers,
            capturedProcesses: [zoomProcess],
            captureGroupKey: captureGroupKey,
            inputDevices: inputDevices,
            discontinuities: discontinuities,
            isFinalized: isFinalized
        )
    }
}

// swiftlint:enable force_try
