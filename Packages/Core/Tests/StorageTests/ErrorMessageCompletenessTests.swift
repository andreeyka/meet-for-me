//  ErrorMessageCompletenessTests — К31 перечня MEE-189 (инвариант 22,
//  полнота message), владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class ErrorMessageCompletenessTests: StorageAsyncTestCase {

    // MARK: - (i) DecodingError — message несёт описание целиком, включая codingPath

    func testK31i_decodingErrorMessageCarriesFullDescriptionWithCodingPath() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        let recordingId = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE recordings SET manifest_json = 'not-json' WHERE id = ?",
                arguments: [recordingId.uuidString]
            )
        }

        // Эталон собирается напрямую, тем же входом — "not-json" через тот же
        // DomainJSON.decode, которым StorageJSON.decodeFromText пользуется
        // внутри StorageErrorMapping.map, — а не походом в БД второй раз и не
        // угаданным литералом: сверка равенством ниже сравнивает ДВА живых
        // результата одного и того же вызова на одном и том же входе.
        let referenceMessage: String
        do {
            _ = try DomainJSON.decode(RecordingManifest.self, from: Data("not-json".utf8))
            XCTFail("эталон обязан бросить"); return
        } catch {
            referenceMessage = String(describing: error)
        }

        do {
            _ = try await recordings.recording(id: recordingId)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted(_, _, let message) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)"); return
            }
            XCTAssertEqual(message, referenceMessage, "полный текст равен эталону, собранному напрямую")
        }
    }

    // MARK: - (ii) DomainValidationError — message несёт номер инварианта и path

    func testK31ii_domainValidationErrorMessageCarriesInvariantAndPath() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()
        let recordingId = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let header = try await transcripts.save(try TestFixtures.transcript(
            recordingId: recordingId, segments: [try TestFixtures.segment(startMs: 0, endMs: 10, text: "x")]
        ))

        // end_ms <= start_ms — синтаксически валидный JSON/строки, но нарушает
        // собственный инвариант конструктора Transcript.Segment (C-003, инв. 3).
        try temp.database.rawWrite { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(
                sql: "UPDATE segments SET start_ms = 100, end_ms = 50 WHERE transcript_id = ?",
                arguments: [header.id.uuidString]
            )
            try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }

        // Эталон собирается напрямую, тем же входом (100, 50) конструктору
        // Transcript.Segment — тот же DomainValidationError, что ловит
        // StorageErrorMapping.map при чтении испорченной строки.
        let referenceMessage: String
        do {
            _ = try Transcript.Segment(
                startMs: 100, endMs: 50, channel: .mic, speakerCluster: nil,
                text: "x", textOriginal: nil, textConfidence: nil, words: []
            )
            XCTFail("эталон обязан бросить"); return
        } catch let error as DomainValidationError {
            referenceMessage = error.description
        }

        do {
            _ = try await transcripts.transcript(id: header.id)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted(_, _, let message) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)"); return
            }
            XCTAssertEqual(message, referenceMessage, "полный текст равен эталону, собранному напрямую")
        }
    }
}
