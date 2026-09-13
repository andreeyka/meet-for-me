//  Раздел В перечня: совместимость с форматом файлов, пп. 14, 15, 18, 19, 20.

import XCTest
import DomainCore

final class FileFormatTests: XCTestCase {

    /// Эталон приходит файлом-ресурсом: `Bundle.module` → `Data` → `DomainJSON.decode(_:from:)`.
    /// Значение, с которым он сравнивается, собрано в коде — файл написан другой стороной.
    func test_p14_manifestReference_decodes() throws {
        let decoded = try DomainJSON.decode(RecordingManifest.self,
                                            from: ReferenceJSON.bytes(of: .manifest))
        XCTAssertEqual(decoded, try ReferenceJSON.expectedManifest())
    }

    func test_p14_transcriptReference_decodes() throws {
        let decoded = try DomainJSON.decode(Transcript.self,
                                            from: ReferenceJSON.bytes(of: .transcript))
        XCTAssertEqual(decoded, try ReferenceJSON.expectedTranscript())
    }

    /// Свойства (а), (б), (в), (д), (е), (ж) эталонов — то, что проверяется текстом.
    func test_p14_referenceProperties_hold() throws {
        let manifestText = try ReferenceJSON.text(of: .manifest)
        XCTAssertTrue(manifestText.contains("\"schemaVersion\": 3"))
        XCTAssertTrue(try ReferenceJSON.text(of: .transcript).contains("\"schemaVersion\": 2"))
        XCTAssertTrue(manifestText.contains("\"present\""))
        XCTAssertTrue(manifestText.contains("\"discontinuities\""))
        XCTAssertTrue(manifestText.contains("\"captureGroupKey\""))
        XCTAssertFalse(manifestText.contains("inputDeviceName"))
        XCTAssertFalse(manifestText.contains("inputDeviceUID"))
        XCTAssertTrue(manifestText.contains("\n"), "эталон записан с переводами строк")
        XCTAssertTrue(manifestText.contains("\"reason\": \"rebuild\""))
        XCTAssertTrue(manifestText.contains("\"scaleErrorMs\": 150"))
        let manifest = try decodeManifest(manifestText)
        let paired = manifest.markers.filter { $0.kind == .discontinuity }.map(\.atMs)
        XCTAssertEqual(paired, manifest.discontinuities.map(\.atMs))
    }

    /// Свойство (з): полнота эталона проверяется против ОБЪЯВЛЕНИЯ типа, а не против списка
    /// имён в пункте. Ожидаемое множество берётся у кодировщика — п. 7 требует кодировать `nil`
    /// отсутствием ключа, поэтому значение со всеми непустыми необязательными полями даёт ровно
    /// каждый объявленный ключ и ни одного лишнего.
    ///
    /// Сверяется ПРЕДЪЯВЛЕНИЕ КЛЮЧА, а не непустота значения: `Word.original` и
    /// `Segment.textOriginal` записаны в эталоне явным `null`, и это предъявление — свойство
    /// говорит про эталон, «молчащий о поле».
    func test_p14_referencesPresentEveryDeclaredField() throws {
        let manifest = try ReferenceJSON.manifestWithEveryFieldFilled()
        try assertPresentsEveryDeclaredField(of: manifest, in: .manifest)
        let transcript = try ReferenceJSON.transcriptWithEveryFieldFilled()
        try assertPresentsEveryDeclaredField(of: transcript, in: .transcript)
    }

    private func assertPresentsEveryDeclaredField<Value: Encodable>(
        of filled: Value,
        in reference: ReferenceJSON.Reference,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let declared = try ReferenceJSON.keyNamesByLevel(inJSON: DomainJSON.encode(filled))
        let shown = try ReferenceJSON.keyNamesByLevel(inJSON: ReferenceJSON.bytes(of: reference))
        XCTAssertFalse(declared.isEmpty, "объявление пусто — признак ничего не проверяет",
                       file: file, line: line)
        for level in declared.keys.sorted() {
            let missing = declared[level, default: []].subtracting(shown[level, default: []])
            XCTAssertEqual(missing.sorted(), [],
                           "эталон \(reference.rawValue).json молчит о полях уровня "
                           + "«\(level.isEmpty ? "<корень>" : level)»",
                           file: file, line: line)
        }
    }

    func test_p15_reference_survivesDecodeEncodeDecode() throws {
        let manifest = try DomainJSON.decode(RecordingManifest.self,
                                             from: ReferenceJSON.bytes(of: .manifest))
        let manifestBack = try DomainJSON.decode(RecordingManifest.self,
                                                 from: DomainJSON.encode(manifest))
        XCTAssertEqual(manifestBack, manifest)

        let transcript = try DomainJSON.decode(Transcript.self,
                                               from: ReferenceJSON.bytes(of: .transcript))
        let transcriptBack = try DomainJSON.decode(Transcript.self,
                                                   from: DomainJSON.encode(transcript))
        XCTAssertEqual(transcriptBack, transcript)
    }

    func test_p18_keyOrderAndWhitespace_doNotChangeResult() throws {
        let manifestText = try ReferenceJSON.text(of: .manifest)
        let dense = manifestText
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "  ", with: "")
        XCTAssertEqual(try decodeManifest(dense), try decodeManifest(manifestText))

        let transcriptText = try ReferenceJSON.text(of: .transcript)
        let spaced = transcriptText.replacingOccurrences(of: ": ", with: "   :   ")
        XCTAssertEqual(try decodeTranscript(spaced), try decodeTranscript(transcriptText))

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
        let bytes = Array(try ReferenceJSON.bytes(of: .manifest))
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
