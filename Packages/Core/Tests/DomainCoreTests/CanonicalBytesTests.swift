//  Канонический вид байтов §0.4: пп. 107—112.

import XCTest
import DomainCore
import DomainTestKit

final class CanonicalBytesTests: XCTestCase {

    func test_p107_dateIsWrittenInCanonicalForm() throws {
        let event = try decodeEvent(EventJSON.text(lastModified: "\"2026-09-11T14:22:33.863Z\""))
        XCTAssertTrue(try encodedText(event).contains("2026-09-11T14:22:33.863Z"))
        let round = try decodeEvent(EventJSON.text(lastModified: "\"2026-09-11T14:22:33Z\""))
        XCTAssertTrue(try encodedText(round).contains("2026-09-11T14:22:33.000Z"))
    }

    func test_p107_fractionIsRoundedToNearestAwayFromZero() throws {
        let up = try decodeEvent(EventJSON.text(lastModified: "\"2026-09-11T14:22:33.8635Z\""))
        XCTAssertTrue(try encodedText(up).contains("14:22:33.864Z"))
        let down = try decodeEvent(EventJSON.text(lastModified: "\"2026-09-11T14:22:33.8634Z\""))
        XCTAssertTrue(try encodedText(down).contains("14:22:33.863Z"))
    }

    func test_p107_readingGrammarIsWiderThanWriting() throws {
        let accepted = ["\"2026-09-11T14:22:33Z\"", "\"2026-09-11T14:22:33.8Z\"",
                        "\"2026-09-11T14:22:33.123456789Z\"", "\"2026-09-11T17:22:33.000+03:00\""]
        for value in accepted {
            XCTAssertNoThrow(try decodeEvent(EventJSON.text(lastModified: value)), value)
        }
        let shifted = try decodeEvent(EventJSON.text(lastModified: "\"2026-09-11T17:22:33.000+03:00\""))
        let zulu = try decodeEvent(EventJSON.text(lastModified: "\"2026-09-11T14:22:33.000Z\""))
        XCTAssertEqual(shifted.lastModified, zulu.lastModified)
    }

    func test_p107_dateGarbageIsRejected() throws {
        for value in ["\"2026-09-11\"", "\"11.09.2026\"", "1757600553.863",
                      "\"2026-09-11T14:22:33\"", "\"10000-01-01T00:00:00.000Z\"",
                      "\"+275760-09-13T00:00:00.000Z\"", "\"-0001-01-01T00:00:00.000Z\"",
                      "\"0000-12-31T23:59:59.999Z\""] {
            assertCorrupted(try decodeEvent(EventJSON.text(lastModified: value)),
                            key: "lastModified")
        }
    }

    func test_p108_uuidIsWrittenInUpperCase() throws {
        let text = try encodedText(try decodeManifest(ManifestJSON.text()))
        XCTAssertTrue(text.contains("3F2504E0-4F89-41D3-9A0C-0305E82C3301"))
        XCTAssertFalse(text.contains("3f2504e0-4f89-41d3-9a0c-0305e82c3301"))
        for value in ["\"{3F2504E0-4F89-41D3-9A0C-0305E82C3301}\"",
                      "\"3F2504E04F8941D39A0C0305E82C3301\""] {
            XCTAssertThrowsError(try decodeManifest(ManifestJSON.text(recordingId: value))) { error in
                XCTAssertTrue(error is DecodingError, "\(error)")
            }
        }
    }

    func test_p109_keysAreSortedRecursively() throws {
        let text = try encodedText(RecordingManifestFixtures.deviceChangedMidway)
        assertKeyOrder(["\"capturedProcesses\"", "\"captureGroupKey\"", "\"directoryName\"",
                        "\"discontinuities\"", "\"endedAt\"", "\"inputDevices\"", "\"isFinalized\"",
                        "\"markers\"", "\"meetingId\"", "\"recordingId\"", "\"schemaVersion\"",
                        "\"startedAt\"", "\"tracks\""], in: text)
        let trackStart = try XCTUnwrap(text.range(of: "\"tracks\""))
        let tail = String(text[trackStart.upperBound...])
        assertKeyOrder(["\"channel\"", "\"channelCount\"", "\"fileName\"", "\"format\"",
                        "\"sampleRate\""], in: tail)
    }

    func test_p109_arrayOrderIsData() throws {
        let reversed = "[\(EventJSON.attendee(email: "\"zz@example.com\"")), " +
            "\(EventJSON.attendee(email: "\"aa@example.com\""))]"
        let decoded = try decodeEvent(EventJSON.text(attendees: reversed))
        XCTAssertEqual(decoded.attendees.first?.person.email, "zz@example.com")
        let back = try DomainJSON.decode(MeetingEvent.self, from: DomainJSON.encode(decoded))
        XCTAssertEqual(back.attendees.map { $0.person.email }, ["zz@example.com", "aa@example.com"])
    }

    func test_p110_outputIsCompact() throws {
        let data = try DomainJSON.encode(RecordingManifestFixtures.deviceChangedMidway)
        let bytes = [UInt8](data)
        XCTAssertFalse(bytes.starts(with: [0xEF, 0xBB, 0xBF]), "BOM")
        XCTAssertNotEqual(bytes.last, 0x0A, "завершающий перевод строки")
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            if byte == 0x22 { inString = true; continue }
            XCTAssertFalse(byte == 0x20 || byte == 0x0A || byte == 0x09, "пробельный байт вне строки")
        }
        XCTAssertEqual(DomainJSON.encoder().outputFormatting,
                       [.sortedKeys, .withoutEscapingSlashes])
    }

    func test_p111_slashIsNotEscapedAndNonASCIIIsWrittenAsIs() throws {
        let text = try encodedText(MeetingEventFixtures.oneOnOneZoom)
        XCTAssertTrue(text.contains("https://zoom.us/j/1234567890"))
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertTrue(text.contains("Синхронизация"))
        XCTAssertFalse(text.contains("\\u0421"))
    }

    func test_p111_escapesAreAcceptedWhenReading() throws {
        let escaped = try decodeEvent(EventJSON.text(
            title: "\"\\u0412\\u0441\\u0442\\u0440\\u0435\\u0447\\u0430\"",
            conference: EventJSON.conference(joinUrl: "\"https:\\/\\/zoom.us\\/j\\/1\"")))
        XCTAssertEqual(escaped.title, "Встреча")
        XCTAssertEqual(escaped.conference?.joinUrl.absoluteString, "https://zoom.us/j/1")
    }

    func test_p112_negativeZeroKeepsItsSign() throws {
        let speaker = try Transcript.Speaker(cluster: 0, embedding: [-0.0],
                                             embeddingModelVersion: "v1", totalMs: 0)
        let source = try Transcript(recordingId: try makeUUID(ManifestJSON.identifier),
                                    language: "ru", engine: "eng", modelVersion: "v1",
                                    createdAt: date(milliseconds: 0), segments: [],
                                    speakers: [speaker])
        let text = try encodedText(source)
        XCTAssertTrue(text.contains("-0"))
        let back = try DomainJSON.decode(Transcript.self, from: DomainJSON.encode(source))
        let value = try XCTUnwrap(back.speakers.first?.embedding?.first)
        XCTAssertEqual(value.bitPattern, Float(-0.0).bitPattern)
    }

    func test_p112_intIsWrittenInDecimalForm() throws {
        let text = try encodedText(try decodeManifest(ManifestJSON.text()))
        XCTAssertTrue(text.contains("48000"))
        XCTAssertFalse(text.contains("4.8e4"))
        XCTAssertFalse(text.contains("48000.0"))
    }

    func test_p112_nonFiniteLiteralsAreRejected() throws {
        for value in ["1e400", "-1e400"] {
            assertCorrupted(try decodeTranscript(TranscriptJSON.text(segments:
                "[\(TranscriptJSON.segment(textConfidence: value))]")), key: "textConfidence")
        }
        let tiny = try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(textConfidence: "1e-400"))]"))
        XCTAssertEqual(tiny.segments.first?.textConfidence, 0.0)
        let half = try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(textConfidence: "5e-1"))]"))
        XCTAssertEqual(half.segments.first?.textConfidence, 0.5)
    }

    /// Элемент `[Float]` проверяется на конечность в `Float`, а не в `Double`.
    func test_p112_floatPrecisionIsCheckedInFloat() throws {
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(speakers:
            "[\(TranscriptJSON.speaker(embedding: "[1e40]", embeddingModelVersion: "\"v1\""))]")),
            key: "embedding")
    }

    private func assertKeyOrder(_ keys: [String], in text: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        var previous = text.startIndex
        for key in keys {
            guard let found = text.range(of: key, range: previous..<text.endIndex) else {
                XCTFail("ключ \(key) не найден в ожидаемом порядке", file: file, line: line)
                return
            }
            previous = found.upperBound
        }
    }
}
