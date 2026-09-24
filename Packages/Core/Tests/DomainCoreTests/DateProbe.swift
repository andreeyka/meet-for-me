//  Значения с одним подменяемым полем `Date` — для пп. 126 и 136.
//
//  Все шесть полей `Date` трёх контрактов проверяются с обеих сторон диапазона: с порядком
//  ступеней (а) → (в) → (б) подпирать соседние поля больше не требуется.

import Foundation
import DomainCore

enum DateProbe {

    private static let validStart = Date(timeIntervalSince1970: 1_789_113_600)
    private static let validEnd = Date(timeIntervalSince1970: 1_789_117_200)

    static func event(start: Date = validStart, end: Date = validEnd,
                      lastModified: Date = validStart) throws -> MeetingEvent {
        try MeetingEvent(
            id: try makeUUID("11111111-1111-4111-8111-111111111111"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: start, end: end, timeZone: "UTC", isAllDay: false, isCancelled: false,
            organizer: nil, attendees: [], location: nil, bodyText: nil,
            conference: nil, lastModified: lastModified
        )
    }

    /// Манифест с непустыми `markers`, `inputDevices` и `discontinuities`: иначе инварианты 11
    /// и 18 не применяются вовсе и вектор проверяет не то, ради чего написан.
    static func manifest(startedAt: Date = validStart,
                         endedAt: Date? = validEnd) throws -> RecordingManifest {
        let recordingId = try makeUUID(ManifestJSON.identifier)
        return try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: startedAt, endedAt: endedAt,
            tracks: [try RecordingManifest.Track(channel: .mic, fileName: "m.caf",
                                                 sampleRate: 48_000, channelCount: 1,
                                                 format: "pcm-caf")],
            markers: [try RecordingManifest.Marker(kind: .discontinuity, atMs: 10, detail: nil)],
            capturedProcesses: [],
            captureGroupKey: nil,
            inputDevices: [try RecordingManifest.InputDeviceSpan(atMs: 0, present: true,
                                                                 name: nil, uid: nil)],
            discontinuities: [try RecordingManifest.Discontinuity(atMs: 10, gapMs: 0,
                                                                  scaleErrorMs: 150,
                                                                  reason: .rebuild)],
            isFinalized: false
        )
    }

    /// Полезная нагрузка коннектора (C-006 §6.1) с тем же валидным окном, что `event`, —
    /// заведена вместе с MEE-346 для перебора инвариантов `MeetingEventPayload`.
    static func payload(start: Date = validStart, end: Date = validEnd,
                        lastModified: Date = validStart) throws -> MeetingEventPayload {
        try MeetingEventPayload(
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: start, end: end, timeZone: "UTC", isAllDay: false, isCancelled: false,
            organizer: nil, attendees: [], location: nil, bodyText: nil,
            conference: nil, lastModified: lastModified
        )
    }

    static func transcript(createdAt: Date = validStart) throws -> Transcript {
        try Transcript(
            recordingId: try makeUUID(ManifestJSON.identifier),
            language: "ru", engine: "gigaam-sherpa-onnx", modelVersion: "v3.0.1",
            createdAt: createdAt, segments: [], speakers: []
        )
    }
}
