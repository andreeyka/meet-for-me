//  Раздел В перечня: совместимость с форматом файлов, пп. 14, 15, 18, 19, 20.

import XCTest
import DomainCore

final class FileFormatTests: XCTestCase {

    func test_p14_manifestReference_decodes() throws {
        let decoded = try decodeManifest(ReferenceJSON.manifest)
        XCTAssertEqual(decoded, try ReferenceJSON.expectedManifest())
    }

    func test_p14_transcriptReference_decodes() throws {
        let decoded = try decodeTranscript(ReferenceJSON.transcript)
        XCTAssertEqual(decoded, try ReferenceJSON.expectedTranscript())
    }

    /// Свойства (а), (б), (в), (д), (е), (ж) эталонов — то, что проверяется текстом.
    func test_p14_referenceProperties_hold() throws {
        XCTAssertTrue(ReferenceJSON.manifest.contains("\"schemaVersion\": 3"))
        XCTAssertTrue(ReferenceJSON.transcript.contains("\"schemaVersion\": 2"))
        XCTAssertTrue(ReferenceJSON.manifest.contains("\"present\""))
        XCTAssertTrue(ReferenceJSON.manifest.contains("\"discontinuities\""))
        XCTAssertTrue(ReferenceJSON.manifest.contains("\"captureGroupKey\""))
        XCTAssertFalse(ReferenceJSON.manifest.contains("inputDeviceName"))
        XCTAssertFalse(ReferenceJSON.manifest.contains("inputDeviceUID"))
        XCTAssertTrue(ReferenceJSON.manifest.contains("\n"), "эталон записан с переводами строк")
        XCTAssertTrue(ReferenceJSON.manifest.contains("\"reason\": \"rebuild\""))
        XCTAssertTrue(ReferenceJSON.manifest.contains("\"scaleErrorMs\": 150"))
        let manifest = try decodeManifest(ReferenceJSON.manifest)
        let paired = manifest.markers.filter { $0.kind == .discontinuity }.map(\.atMs)
        XCTAssertEqual(paired, manifest.discontinuities.map(\.atMs))
    }

    func test_p15_reference_survivesDecodeEncodeDecode() throws {
        let manifest = try decodeManifest(ReferenceJSON.manifest)
        let manifestBack = try DomainJSON.decode(RecordingManifest.self,
                                                 from: DomainJSON.encode(manifest))
        XCTAssertEqual(manifestBack, manifest)

        let transcript = try decodeTranscript(ReferenceJSON.transcript)
        let transcriptBack = try DomainJSON.decode(Transcript.self,
                                                   from: DomainJSON.encode(transcript))
        XCTAssertEqual(transcriptBack, transcript)
    }

    func test_p18_keyOrderAndWhitespace_doNotChangeResult() throws {
        let dense = ReferenceJSON.manifest
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "  ", with: "")
        XCTAssertEqual(try decodeManifest(dense), try decodeManifest(ReferenceJSON.manifest))

        let spaced = ReferenceJSON.transcript.replacingOccurrences(of: ": ", with: "   :   ")
        XCTAssertEqual(try decodeTranscript(spaced), try decodeTranscript(ReferenceJSON.transcript))

        let reordered = """
        {"lastModified": "2026-09-10T12:00:00.000Z", "attendees": [], "title": "T", \
        "isCancelled": false, "isAllDay": false, "timeZone": "UTC", \
        "end": "2026-09-11T09:00:00.000Z", "start": "2026-09-11T08:00:00.000Z", \
        "externalId": "evt-1", "sourceConnectorId": "eventkit", \
        "id": "11111111-1111-4111-8111-111111111111"}
        """
        let straight = EventJSON.text(title: "\"T\"", start: "\"2026-09-11T08:00:00.000Z\"",
                                      end: "\"2026-09-11T09:00:00.000Z\"", timeZone: "\"UTC\"")
        XCTAssertEqual(try decodeEvent(reordered), try decodeEvent(straight))
    }

    /// Обрезанный файл — отказ разбора, а не частично заполненный объект; процесс не падает.
    func test_p19_truncatedReference_isRejected() throws {
        let bytes = Array(ReferenceJSON.manifest.utf8)
        let prefix = Data(bytes.prefix(bytes.count * 3 / 5))
        XCTAssertThrowsError(try DomainJSON.decode(RecordingManifest.self, from: prefix)) { error in
            XCTAssertTrue(error is DecodingError, "ожидался DecodingError, получено \(error)")
        }
    }

    func test_p20_emptyData_isDataCorrupted() {
        XCTAssertThrowsError(try DomainJSON.decode(RecordingManifest.self, from: Data())) { error in
            guard let decoding = error as? DecodingError,
                  case .dataCorrupted = decoding else {
                XCTFail("ожидался dataCorrupted, получено \(error)")
                return
            }
        }
    }

    func test_p20_emptyObject_isKeyNotFound() {
        let roots: Set<String> = ["schemaVersion", "recordingId", "meetingId", "directoryName",
                                  "startedAt", "endedAt", "tracks", "markers", "capturedProcesses",
                                  "captureGroupKey", "inputDevices", "discontinuities", "isFinalized"]
        XCTAssertThrowsError(try decodeManifest("{}")) { error in
            guard let decoding = error as? DecodingError,
                  case .keyNotFound(let missing, _) = decoding else {
                XCTFail("ожидался keyNotFound, получено \(error)")
                return
            }
            XCTAssertTrue(roots.contains(missing.stringValue), missing.stringValue)
        }
    }
}
