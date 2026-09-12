//  Эталонные тексты `manifest.json` и `transcript.v1.json` — п. 14 перечня.
//
//  Написаны вручную, а не получены из кодировщика проекта: вывод `DomainJSON` компактен
//  и с сортированными ключами, а здесь и отступы, и произвольный порядок ключей. Это
//  одновременно доказывает ручное написание и проверяет терпимое чтение, которого §0.4
//  требует прямо. Файлами они не лежат: `resources:` тестового таргета объявляются в чужом
//  `Package.swift`, а каталог `Fixtures/` принадлежит архитектору и описывает издания v2.
//
//  Повторяющихся ключей здесь нет ни на одном уровне; все целые записаны десятичной записью
//  без экспоненты и дробной части и лежат в ±(2^53 − 1).

import Foundation
import DomainCore

enum ReferenceJSON {

    /// `manifest.json` схемы 3: со спанами `present`, разрывами и ключом группы захвата.
    static let manifest = """
    {
      "schemaVersion": 3,
      "recordingId": "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
      "directoryName": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
      "meetingId": null,
      "startedAt": "2026-09-11T09:30:00.000Z",
      "endedAt": "2026-09-11T10:31:20.500+00:00",
      "isFinalized": true,
      "captureGroupKey": "bundle:us.zoom.xos",
      "tracks": [
        {
          "channel": "mic",
          "fileName": "audio-mic.m4a",
          "sampleRate": 48000,
          "channelCount": 1,
          "format": "aac-m4a"
        },
        {
          "channel": "system",
          "fileName": "audio-system.m4a",
          "sampleRate": 48000,
          "channelCount": 2,
          "format": "aac-m4a"
        }
      ],
      "markers": [
        { "kind": "sleep",         "atMs": 1800000 },
        { "kind": "discontinuity", "atMs": 1800000, "detail": "aggregate device rebuilt" },
        { "kind": "wake",          "atMs": 1802000 },
        { "kind": "deviceChanged", "atMs": 2400000, "detail": "встроенный -> AirPods" }
      ],
      "discontinuities": [
        { "atMs": 1800000, "gapMs": 2000, "scaleErrorMs": 150, "reason": "rebuild" }
      ],
      "inputDevices": [
        {
          "atMs": 0,
          "present": true,
          "name": "MacBook Pro Microphone",
          "uid": "BuiltInMicrophoneDevice"
        },
        { "atMs": 2400000, "present": true, "name": "AirPods Pro", "uid": "A1B2C3-airpods" }
      ],
      "capturedProcesses": [
        { "pid": 4821, "bundleId": "us.zoom.xos", "executableName": "zoom.us" }
      ]
    }
    """

    /// `transcript.v1.json` схемы 2.
    static let transcript = """
    {
      "schemaVersion": 2,
      "recordingId": "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
      "language": "ru",
      "engine": "gigaam-sherpa-onnx",
      "modelVersion": "v3.0.1",
      "createdAt": "2026-09-11T10:35:12.250Z",
      "speakers": [
        {
          "cluster": 0,
          "totalMs": 3000,
          "embedding": [0.5, -0.25],
          "embeddingModelVersion": "emb-v1"
        }
      ],
      "segments": [
        {
          "startMs": 1200,
          "endMs": 3400,
          "channel": "mic",
          "speakerCluster": null,
          "text": "Привет, начнём.",
          "textConfidence": 0.88,
          "words": [
            { "startMs": 1200, "endMs": 1900, "text": "Привет,", "confidence": 0.94 },
            { "startMs": 1900, "endMs": 2600, "text": "начнём.", "confidence": 0.88 }
          ]
        },
        {
          "startMs": 3000,
          "endMs": 6000,
          "channel": "system",
          "speakerCluster": 0,
          "text": "Да, я готов.",
          "textConfidence": 0.7,
          "words": []
        },
        {
          "startMs": 6100,
          "endMs": 6500,
          "channel": "system",
          "speakerCluster": null,
          "text": "   ",
          "textConfidence": null,
          "words": []
        }
      ]
    }
    """

    /// То же значение, собранное в коде: с ним сравнивается разобранный эталон.
    static func expectedManifest() throws -> RecordingManifest {
        let recordingId = try makeUUID("3F2504E0-4F89-41D3-9A0C-0305E82C3301")
        return try RecordingManifest(
            recordingId: recordingId,
            meetingId: nil,
            directoryName: recordingId.uuidString,
            startedAt: date(milliseconds: 1_789_119_000_000),
            endedAt: date(milliseconds: 1_789_122_680_500),
            tracks: [
                try RecordingManifest.Track(channel: .mic, fileName: "audio-mic.m4a",
                                            sampleRate: 48_000, channelCount: 1, format: "aac-m4a"),
                try RecordingManifest.Track(channel: .system, fileName: "audio-system.m4a",
                                            sampleRate: 48_000, channelCount: 2, format: "aac-m4a")
            ],
            markers: [
                try RecordingManifest.Marker(kind: .sleep, atMs: 1_800_000, detail: nil),
                try RecordingManifest.Marker(kind: .discontinuity, atMs: 1_800_000,
                                             detail: "aggregate device rebuilt"),
                try RecordingManifest.Marker(kind: .wake, atMs: 1_802_000, detail: nil),
                try RecordingManifest.Marker(kind: .deviceChanged, atMs: 2_400_000,
                                             detail: "встроенный -> AirPods")
            ],
            capturedProcesses: [
                try RecordingManifest.CapturedProcess(pid: 4_821, bundleId: "us.zoom.xos",
                                                      executableName: "zoom.us")
            ],
            captureGroupKey: "bundle:us.zoom.xos",
            inputDevices: [
                try RecordingManifest.InputDeviceSpan(atMs: 0, present: true,
                                                      name: "MacBook Pro Microphone",
                                                      uid: "BuiltInMicrophoneDevice"),
                try RecordingManifest.InputDeviceSpan(atMs: 2_400_000, present: true,
                                                      name: "AirPods Pro", uid: "A1B2C3-airpods")
            ],
            discontinuities: [
                try RecordingManifest.Discontinuity(atMs: 1_800_000, gapMs: 2_000,
                                                    scaleErrorMs: 150, reason: .rebuild)
            ],
            isFinalized: true
        )
    }

    static func expectedTranscript() throws -> Transcript {
        try Transcript(
            recordingId: try makeUUID("3F2504E0-4F89-41D3-9A0C-0305E82C3301"),
            language: "ru",
            engine: "gigaam-sherpa-onnx",
            modelVersion: "v3.0.1",
            createdAt: date(milliseconds: 1_789_122_912_250),
            segments: [
                try Transcript.Segment(
                    startMs: 1_200, endMs: 3_400, channel: .mic, speakerCluster: nil,
                    text: "Привет, начнём.", textOriginal: nil, textConfidence: 0.88,
                    words: [
                        try Transcript.Word(startMs: 1_200, endMs: 1_900, text: "Привет,",
                                            confidence: 0.94, original: nil),
                        try Transcript.Word(startMs: 1_900, endMs: 2_600, text: "начнём.",
                                            confidence: 0.88, original: nil)
                    ]
                ),
                try Transcript.Segment(
                    startMs: 3_000, endMs: 6_000, channel: .system, speakerCluster: 0,
                    text: "Да, я готов.", textOriginal: nil, textConfidence: 0.7, words: []
                ),
                try Transcript.Segment(
                    startMs: 6_100, endMs: 6_500, channel: .system, speakerCluster: nil,
                    text: "   ", textOriginal: nil, textConfidence: nil, words: []
                )
            ],
            speakers: [
                try Transcript.Speaker(cluster: 0, embedding: [0.5, -0.25],
                                       embeddingModelVersion: "emb-v1", totalMs: 3_000)
            ]
        )
    }
}
