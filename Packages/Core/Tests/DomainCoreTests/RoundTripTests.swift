//  Раздел Б перечня: круговое преобразование, пп. 6, 7, 11, 12, 13.

import XCTest
import DomainCore
import DomainTestKit

final class RoundTripTests: XCTestCase {

    func test_p6_allFixtures_roundTripByEquality() throws {
        for fixture in MeetingEventFixtures.allFixtures {
            let back = try DomainJSON.decode(MeetingEvent.self, from: DomainJSON.encode(fixture))
            XCTAssertEqual(back, fixture)
        }
        for fixture in RecordingManifestFixtures.allFixtures {
            let back = try DomainJSON.decode(RecordingManifest.self, from: DomainJSON.encode(fixture))
            XCTAssertEqual(back, fixture)
        }
        for fixture in TranscriptFixtures.allFixtures {
            let back = try DomainJSON.decode(Transcript.self, from: DomainJSON.encode(fixture))
            XCTAssertEqual(back, fixture)
        }
    }

    func test_p7_nilField_isEncodedAsMissingKey() throws {
        let text = try encodedText(MeetingEventFixtures.withoutConference)
        XCTAssertFalse(text.contains("icalUid"), "ключ nil-поля не пишется вовсе")
        XCTAssertFalse(text.contains("conference"))
        XCTAssertFalse(text.contains("null"), "null в каноническом выводе не появляется")
        let manifest = try encodedText(RecordingManifestFixtures.unfinished)
        XCTAssertFalse(manifest.contains("endedAt"))
        XCTAssertFalse(manifest.contains("captureGroupKey"))
    }

    func test_p11_encodeDecodeEncode_isByteIdentical() throws {
        for fixture in MeetingEventFixtures.allFixtures {
            let first = try DomainJSON.encode(fixture)
            let second = try DomainJSON.encode(DomainJSON.decode(MeetingEvent.self, from: first))
            XCTAssertEqual(first, second)
        }
        for fixture in RecordingManifestFixtures.allFixtures {
            let first = try DomainJSON.encode(fixture)
            let second = try DomainJSON.encode(DomainJSON.decode(RecordingManifest.self, from: first))
            XCTAssertEqual(first, second)
        }
        for fixture in TranscriptFixtures.allFixtures {
            let first = try DomainJSON.encode(fixture)
            let second = try DomainJSON.encode(DomainJSON.decode(Transcript.self, from: first))
            XCTAssertEqual(first, second)
        }
    }

    /// Литеральный эталон вывода: фикстура выбрана так, что все её поля заданы правилами
    /// §0.4 однозначно — вещественных с длинной мантиссой в ней нет.
    func test_p11_encoderOutput_matchesLiteral() throws {
        let expected = "{\"attendees\":[],\"end\":\"2026-09-11T09:00:00.000Z\","
            + "\"externalId\":\"evt-1002\",\"id\":\"22222222-2222-4222-8222-222222222222\","
            + "\"isAllDay\":false,\"isCancelled\":false,"
            + "\"lastModified\":\"2026-09-10T12:00:00.000Z\","
            + "\"sourceConnectorId\":\"eventkit\",\"start\":\"2026-09-11T08:00:00.000Z\","
            + "\"timeZone\":\"UTC\",\"title\":\"\"}"
        XCTAssertEqual(try encodedText(MeetingEventFixtures.withoutConference), expected)
    }

    func test_p12_doubleAndFloat_surviveBitwise() throws {
        let embedding: [Float] = [-0.0, .leastNonzeroMagnitude, 1_234_567.0]
        let speaker = try Transcript.Speaker(cluster: 0, embedding: embedding,
                                            embeddingModelVersion: "emb-v1", totalMs: 0)
        let source = try Transcript(recordingId: makeUUID("3F2504E0-4F89-41D3-9A0C-0305E82C3301"),
                                    language: "ru", engine: "eng", modelVersion: "v1",
                                    createdAt: date(milliseconds: 1_789_122_912_000),
                                    segments: [], speakers: [speaker])
        let back = try DomainJSON.decode(Transcript.self, from: DomainJSON.encode(source))
        let restored = try XCTUnwrap(back.speakers.first?.embedding)
        XCTAssertEqual(restored.count, embedding.count)
        for (position, value) in embedding.enumerated() {
            XCTAssertEqual(restored[position].bitPattern, value.bitPattern, "элемент \(position)")
        }
    }

    func test_p12_doubleConfidence_survivesBitwise() throws {
        for value in [0.1, 0.7] {
            let text = TranscriptJSON.text(
                segments: "[\(TranscriptJSON.segment(textConfidence: "\(value)", words: "[]"))]"
            )
            let decoded = try decodeTranscript(text)
            let confidence = try XCTUnwrap(decoded.segments.first?.textConfidence)
            XCTAssertEqual(confidence.bitPattern, value.bitPattern)
        }
    }

    func test_p12_alignedDate_survivesExactly() throws {
        let aligned = date(milliseconds: 1_789_113_600_123)
        let event = try makeEvent(lastModified: aligned)
        let back = try DomainJSON.decode(MeetingEvent.self, from: DomainJSON.encode(event))
        XCTAssertEqual(back.lastModified, aligned)
    }

    /// Не выровненная по миллисекунде дата на круге исходной не равна: §0.4 округляет запись.
    func test_p12_unalignedDate_isRoundedNotPreserved() throws {
        let unaligned = Date(timeIntervalSince1970: 1_789_113_600.0004)
        let event = try makeEvent(lastModified: unaligned)
        let back = try DomainJSON.decode(MeetingEvent.self, from: DomainJSON.encode(event))
        XCTAssertNotEqual(back.lastModified, unaligned)
        XCTAssertEqual(back.lastModified, Date(timeIntervalSince1970: 1_789_113_600))
    }

    func test_p12_uuid_readsAnyCaseWritesUpper() throws {
        let lower = try decodeEvent(EventJSON.text(id: "\"3f2504e0-4f89-41d3-9a0c-0305e82c3301\""))
        let upper = try decodeEvent(EventJSON.text(id: "\"3F2504E0-4F89-41D3-9A0C-0305E82C3301\""))
        XCTAssertEqual(lower, upper)
        let text = try encodedText(lower)
        XCTAssertTrue(text.contains("3F2504E0-4F89-41D3-9A0C-0305E82C3301"))
        XCTAssertFalse(text.contains("3f2504e0-4f89-41d3-9a0c-0305e82c3301"))
    }

    func test_p13_strings_surviveRoundTrip() throws {
        let samples = ["Встреча 🙂", "строка\tс\nпереводами", "\u{00A0}мягкий\u{00AD}перенос",
                       String(repeating: "я", count: 1_000)]
        for sample in samples {
            let event = try makeEvent(title: sample)
            let back = try DomainJSON.decode(MeetingEvent.self, from: DomainJSON.encode(event))
            XCTAssertEqual(back.title, sample)
        }
    }

    func test_p13_emojiOutsideBMP_survivesRoundTrip() throws {
        let sample = "\u{1F469}\u{200D}\u{1F4BB}"
        let event = try makeEvent(title: sample)
        let back = try DomainJSON.decode(MeetingEvent.self, from: DomainJSON.encode(event))
        XCTAssertEqual(back.title, sample)
    }

    private func makeEvent(title: String = "Синхронизация",
                           lastModified: Date = Date(timeIntervalSince1970: 1_789_041_600))
    throws -> MeetingEvent {
        try MeetingEvent(
            id: makeUUID("11111111-1111-4111-8111-111111111111"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil,
            title: title,
            start: Date(timeIntervalSince1970: 1_789_113_600),
            end: Date(timeIntervalSince1970: 1_789_117_200),
            timeZone: "UTC", isAllDay: false, isCancelled: false,
            organizer: nil, attendees: [], location: nil, bodyText: nil,
            conference: nil, lastModified: lastModified
        )
    }
}
