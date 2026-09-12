//  Раздел Б перечня: пп. 8, 9, 10 — `nil`, пустые коллекции и отсутствующие ключи.
//
//  Перечень полей есть признак §0.4, применённый к объявлениям: под п. 8 подпадает каждое
//  опциональное поле каждого типа C-001…C-003 — двадцать четыре поля.

import XCTest
import DomainCore
import DomainTestKit

final class OptionalAndCollectionTests: XCTestCase {

    // MARK: - п. 8: отсутствующий ключ и явный `null` — одно значение

    func test_p8_event_explicitNullEqualsMissingKey() throws {
        let text = EventJSON.text(
            organizer: EventJSON.person(name: "null", email: "null"),
            conference: EventJSON.conference()
        )
        for key in ["icalUid", "location", "bodyText", "name", "meetingId", "passcode"] {
            XCTAssertEqual(try decodeEvent(text), try decodeEvent(withoutNullKey(text, key)), key)
        }
        let withoutOrganizer = EventJSON.text(organizer: "null", conference: "null")
        for key in ["organizer", "conference"] {
            XCTAssertEqual(try decodeEvent(withoutOrganizer),
                           try decodeEvent(withoutNullKey(withoutOrganizer, key)), key)
        }
        let emailCase = EventJSON.text(attendees: "[\(EventJSON.attendee(email: "null"))]")
        XCTAssertEqual(try decodeEvent(emailCase), try decodeEvent(withoutNullKey(emailCase, "email")))
    }

    func test_p8_manifest_explicitNullEqualsMissingKey() throws {
        let text = ManifestJSON.text(
            endedAt: "null",
            markers: "[\(ManifestJSON.marker())]",
            capturedProcesses: "[\(ManifestJSON.process(bundleId: "null", executableName: "null"))]",
            inputDevices: "[\(ManifestJSON.span())]",
            isFinalized: "false"
        )
        for key in ["meetingId", "endedAt", "captureGroupKey", "detail",
                    "bundleId", "executableName", "name", "uid"] {
            XCTAssertEqual(try decodeManifest(text),
                           try decodeManifest(withoutNullKey(text, key)), key)
        }
    }

    func test_p8_transcript_explicitNullEqualsMissingKey() throws {
        let word = TranscriptJSON.word()
        let segment = TranscriptJSON.segment(words: "[\(word)]")
        let text = TranscriptJSON.text(segments: "[\(segment)]",
                                       speakers: "[\(TranscriptJSON.speaker())]")
        for key in ["confidence", "original", "speakerCluster", "textOriginal", "textConfidence"] {
            XCTAssertEqual(try decodeTranscript(text),
                           try decodeTranscript(withoutNullKey(text, key)), key)
        }
        for key in ["embedding", "embeddingModelVersion"] {
            let stripped = withoutNullKey(withoutNullKey(text, "embedding"), "embeddingModelVersion")
            XCTAssertEqual(try decodeTranscript(text), try decodeTranscript(stripped), key)
        }
        let decoded = try decodeTranscript(text)
        XCTAssertNil(decoded.speakers.first?.embedding)
        XCTAssertNil(decoded.speakers.first?.embeddingModelVersion)
    }

    // MARK: - п. 9: пустая коллекция переживает круг как пустая коллекция

    func test_p9_emptyCollections_surviveAsEmpty() throws {
        let event = try DomainJSON.decode(MeetingEvent.self,
                                          from: DomainJSON.encode(MeetingEventFixtures.withoutConference))
        XCTAssertEqual(event.attendees, [])
        XCTAssertTrue(try encodedText(MeetingEventFixtures.withoutConference).contains("\"attendees\":[]"))

        let manifest = try decodeManifest(ManifestJSON.text(isFinalized: "true"))
        let manifestBack = try DomainJSON.decode(RecordingManifest.self,
                                                 from: DomainJSON.encode(manifest))
        XCTAssertEqual(manifestBack.markers, [])
        XCTAssertEqual(manifestBack.capturedProcesses, [])
        XCTAssertEqual(manifestBack.inputDevices, [])
        XCTAssertEqual(manifestBack.discontinuities, [])
        let manifestText = try encodedText(manifest)
        for key in ["markers", "capturedProcesses", "inputDevices", "discontinuities"] {
            XCTAssertTrue(manifestText.contains("\"\(key)\":[]"), key)
        }

        let transcript = try DomainJSON.decode(Transcript.self,
                                               from: DomainJSON.encode(TranscriptFixtures.empty))
        XCTAssertEqual(transcript.segments, [])
        XCTAssertEqual(transcript.speakers, [])
        let wordsText = try encodedText(TranscriptFixtures.segmentWithoutWords)
        XCTAssertTrue(wordsText.contains("\"words\":[]"))
    }

    // MARK: - п. 10: отсутствие ключа обязательной коллекции — отказ разбора

    func test_p10_missingRequiredCollection_isKeyNotFound() throws {
        let event = EventJSON.text()
        assertKeyNotFound(try decodeEvent(withoutArrayKey(event, "attendees")), key: "attendees")

        let manifest = ManifestJSON.text()
        for key in ["tracks", "markers", "capturedProcesses", "inputDevices", "discontinuities"] {
            assertKeyNotFound(try decodeManifest(withoutArrayKey(manifest, key)), key: key)
        }

        let transcript = TranscriptJSON.text()
        for key in ["segments", "speakers"] {
            assertKeyNotFound(try decodeTranscript(withoutArrayKey(transcript, key)), key: key)
        }

        let segment = withoutArrayKey(TranscriptJSON.segment(), "words")
        assertKeyNotFound(try decodeTranscript(TranscriptJSON.text(segments: "[\(segment)]")),
                          key: "words")
    }
}
