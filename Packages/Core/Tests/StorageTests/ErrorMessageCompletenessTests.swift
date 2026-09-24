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

        do {
            _ = try await recordings.recording(id: recordingId)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted(_, _, let message) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)"); return
            }
            // Полное литеральное равенство с НЕЗАВИСИМЫМ повторным разбором того же
            // текста здесь не проверяется намеренно — уже найденный в части 3a баг
            // теста К35 показал, что порядок печати `userInfo` обёрнутой `NSError`
            // (`NSDebugDescription`/`NSJSONSerializationErrorIndex`) не гарантирован
            // между двумя ОТДЕЛЬНЫМИ разборами одного и того же входа. Вместо этого
            // сверяются все детерминированные части «целиком» — точный префикс,
            // оба имени ключей `userInfo` (независимо от их взаимного порядка) и
            // точный конец строки, — так что где бы текст ни был обрезан, проверка
            // это поймает, не полагаясь на порядок недетерминированной середины.
            XCTAssertTrue(
                message.hasPrefix(
                    "dataCorrupted(Swift.DecodingError.Context(codingPath: [], debugDescription: "
                        + "\"The given data was not valid JSON.\", underlyingError: "
                        + "Optional(Error Domain=NSCocoaErrorDomain Code=3840"
                ),
                "точное начало описания DecodingError, не усечено и не подменено: \(message)"
            )
            XCTAssertTrue(message.contains("NSDebugDescription"), "первый ключ userInfo цел: \(message)")
            XCTAssertTrue(message.contains("NSJSONSerializationErrorIndex"), "второй ключ userInfo цел: \(message)")
            XCTAssertTrue(message.hasSuffix("})))"), "текст завершён всеми закрывающими скобками: \(message)")
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

        do {
            _ = try await transcripts.transcript(id: header.id)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted(_, _, let message) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)"); return
            }
            // `DomainValidationError.description` — ровно
            // "\(contract).\(type) инв. \(invariant), \(path): \(message)" (шапка
            // DomainValidationError.swift). Контракт §0.1 сам называет стабильными
            // только contract/type/invariant/path — свободный текст `message` в
            // конце явно объявлен нестабильным и сравнению не подлежит. Поэтому
            // «целиком» здесь значит: весь префикс до двоеточия, всеми четырьмя
            // полями сразу и в точном формате, а не по одному разрозненными
            // подстроками — не только «где-то есть 3» и «где-то есть endMs».
            XCTAssertTrue(
                message.hasPrefix("C-003.Transcript.Segment инв. 3, endMs: "),
                "полный префикс — contract, type, номер инварианта и path одной строкой: \(message)"
            )
        }
    }
}
