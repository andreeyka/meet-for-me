//  Сборка входного текста JSON: базовое валидное значение плюс подменяемые фрагменты.
//
//  Фрагменты подаются текстом, а не значениями Swift, намеренно: вход теста обязан быть
//  тем же, что придёт из файла, — вместе с формой литерала, порядком ключей и пробелами.

import Foundation

enum EventJSON {

    static let identifier = "\"11111111-1111-4111-8111-111111111111\""

    static func text(
        id: String = identifier,
        title: String = "\"Синхронизация\"",
        start: String = "\"2026-09-11T09:30:00.000Z\"",
        end: String = "\"2026-09-11T10:00:00.000Z\"",
        timeZone: String = "\"Europe/Moscow\"",
        isAllDay: String = "false",
        organizer: String = "null",
        attendees: String = "[]",
        conference: String = "null",
        icalUid: String = "null",
        location: String = "null",
        bodyText: String = "null",
        lastModified: String = "\"2026-09-10T12:00:00.000Z\"",
        tail: String = ""
    ) -> String {
        """
        {"id": \(id), "sourceConnectorId": "eventkit", "externalId": "evt-1", \
        "icalUid": \(icalUid), "title": \(title), "start": \(start), "end": \(end), \
        "timeZone": \(timeZone), "isAllDay": \(isAllDay), "isCancelled": false, \
        "organizer": \(organizer), "attendees": \(attendees), "location": \(location), \
        "bodyText": \(bodyText), "conference": \(conference), \
        "lastModified": \(lastModified)\(tail)}
        """
    }

    static func person(name: String = "\"Иван\"", email: String) -> String {
        "{\"name\": \(name), \"email\": \(email)}"
    }

    static func attendee(email: String, status: String = "\"accepted\"") -> String {
        "{\"person\": \(person(email: email)), \"responseStatus\": \(status), \"isOptional\": false}"
    }

    static func conference(
        provider: String = "\"zoom\"",
        joinUrl: String = "\"https://zoom.us/j/1\"",
        tail: String = ""
    ) -> String {
        "{\"provider\": \(provider), \"joinUrl\": \(joinUrl), " +
        "\"meetingId\": null, \"passcode\": null\(tail)}"
    }
}

enum ManifestJSON {

    static let identifier = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"

    static func text(
        schemaVersion: String = "3",
        recordingId: String = "\"\(identifier)\"",
        directoryName: String = "\"\(identifier)\"",
        meetingId: String = "null",
        startedAt: String = "\"2026-09-11T08:00:00.000Z\"",
        endedAt: String = "\"2026-09-11T09:00:00.000Z\"",
        tracks: String = "[\(track()), \(track(channel: "\"system\"", fileName: "\"s.m4a\""))]",
        markers: String = "[]",
        capturedProcesses: String = "[]",
        captureGroupKey: String = "null",
        inputDevices: String = "[]",
        discontinuities: String = "[]",
        isFinalized: String = "true",
        tail: String = ""
    ) -> String {
        """
        {"schemaVersion": \(schemaVersion), "recordingId": \(recordingId), \
        "meetingId": \(meetingId), "directoryName": \(directoryName), \
        "startedAt": \(startedAt), "endedAt": \(endedAt), "tracks": \(tracks), \
        "markers": \(markers), "capturedProcesses": \(capturedProcesses), \
        "captureGroupKey": \(captureGroupKey), "inputDevices": \(inputDevices), \
        "discontinuities": \(discontinuities), "isFinalized": \(isFinalized)\(tail)}
        """
    }

    static func track(
        channel: String = "\"mic\"",
        fileName: String = "\"m.m4a\"",
        sampleRate: String = "48000",
        channelCount: String = "1",
        format: String = "\"aac-m4a\"",
        tail: String = ""
    ) -> String {
        "{\"channel\": \(channel), \"fileName\": \(fileName), \"sampleRate\": \(sampleRate), " +
        "\"channelCount\": \(channelCount), \"format\": \(format)\(tail)}"
    }

    static func marker(kind: String = "\"pause\"", atMs: String = "0",
                       detail: String = "null", tail: String = "") -> String {
        "{\"kind\": \(kind), \"atMs\": \(atMs), \"detail\": \(detail)\(tail)}"
    }

    static func process(pid: String = "4821", bundleId: String = "\"us.zoom.xos\"",
                        executableName: String = "\"zoom.us\"", tail: String = "") -> String {
        "{\"pid\": \(pid), \"bundleId\": \(bundleId), " +
        "\"executableName\": \(executableName)\(tail)}"
    }

    static func span(atMs: String = "0", present: String = "true",
                     name: String = "null", uid: String = "null", tail: String = "") -> String {
        "{\"atMs\": \(atMs), \"present\": \(present), \"name\": \(name), \"uid\": \(uid)\(tail)}"
    }

    static func gap(atMs: String = "0", gapMs: String = "0", scaleErrorMs: String = "150",
                    reason: String = "\"rebuild\"", tail: String = "") -> String {
        "{\"atMs\": \(atMs), \"gapMs\": \(gapMs), \"scaleErrorMs\": \(scaleErrorMs), " +
        "\"reason\": \(reason)\(tail)}"
    }
}

enum TranscriptJSON {

    static let identifier = "\"3F2504E0-4F89-41D3-9A0C-0305E82C3301\""

    static func text(
        schemaVersion: String = "2",
        recordingId: String = identifier,
        language: String = "\"ru\"",
        engine: String = "\"gigaam-sherpa-onnx\"",
        modelVersion: String = "\"v3.0.1\"",
        createdAt: String = "\"2026-09-11T10:35:12.000Z\"",
        segments: String = "[]",
        speakers: String = "[]",
        tail: String = ""
    ) -> String {
        """
        {"schemaVersion": \(schemaVersion), "recordingId": \(recordingId), \
        "language": \(language), "engine": \(engine), "modelVersion": \(modelVersion), \
        "createdAt": \(createdAt), "segments": \(segments), "speakers": \(speakers)\(tail)}
        """
    }

    static func segment(
        startMs: String = "0",
        endMs: String = "1000",
        channel: String = "\"mic\"",
        speakerCluster: String = "null",
        text: String = "\"речь\"",
        textOriginal: String = "null",
        textConfidence: String = "null",
        words: String = "[]",
        tail: String = ""
    ) -> String {
        "{\"startMs\": \(startMs), \"endMs\": \(endMs), \"channel\": \(channel), " +
        "\"speakerCluster\": \(speakerCluster), \"text\": \(text), " +
        "\"textOriginal\": \(textOriginal), \"textConfidence\": \(textConfidence), " +
        "\"words\": \(words)\(tail)}"
    }

    static func word(startMs: String = "0", endMs: String = "500", text: String = "\"да\"",
                     confidence: String = "null", original: String = "null",
                     tail: String = "") -> String {
        "{\"startMs\": \(startMs), \"endMs\": \(endMs), \"text\": \(text), " +
        "\"confidence\": \(confidence), \"original\": \(original)\(tail)}"
    }

    static func speaker(cluster: String = "0", embedding: String = "null",
                        embeddingModelVersion: String = "null", totalMs: String = "0",
                        tail: String = "") -> String {
        "{\"cluster\": \(cluster), \"embedding\": \(embedding), " +
        "\"embeddingModelVersion\": \(embeddingModelVersion), \"totalMs\": \(totalMs)\(tail)}"
    }
}
