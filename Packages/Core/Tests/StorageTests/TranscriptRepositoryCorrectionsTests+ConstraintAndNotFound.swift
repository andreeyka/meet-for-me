//  TranscriptRepositoryCorrectionsTests — constraintViolation/notFound секции, разнесённые
//  по объёму (`type_body_length` SwiftLint, MEE-398), не по смыслу — `extension` того же
//  класса, что и `TranscriptRepositoryCorrectionsTests.swift`. `Fixture`/`makeFixture(_:)`
//  живут там.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import GRDB
import DomainCore
@testable import Storage

extension TranscriptRepositoryCorrectionsTests {

    // MARK: - constraintViolation — строка не меняется целиком

    /// К96 (перечень MEE-189, дельта Х): атомарность отказа — все ЧЕТЫРЕ поля строки,
    /// не только `text`.
    func test_k96_constraintViolationForWordIndexOutOfRangeLeavesAllFourFieldsUntouched() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)
        let correction = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 99, original: "x", replacement: "y",
            personId: UUID(), similarity: 0.9
        )
        do {
            try await fixture.transcripts.applyTextCorrections(
                segmentId: fixture.segmentId, text: "не должно примениться", corrections: [correction]
            )
            XCTFail("ожидался constraintViolation")
        } catch let error as StorageError {
            guard case .constraintViolation = error else { return XCTFail("получено \(error)") }
        }
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, fixture.originalText, "text не изменился — отказ до записи")
        XCTAssertNil(row.segment.textOriginal, "text_original не тронут")
        XCTAssertEqual(row.segment.words, fixture.words, "words_json не тронут целиком")
        XCTAssertFalse(row.isUserEdited, "is_user_edited не тронут")
    }

    /// Смешанный вход: первая правка в диапазоне, вторая — нет. Валидация — до записи
    /// (`requireApplicable`/`applyCorrections`), поэтому даже первая, сама по себе годная,
    /// правка не применяется — строка не меняется НИ В ОДНОМ поле.
    func test_inv32_mixedInputSecondCorrectionOutOfRangeChangesNothing() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)
        let valid = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "привет", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )
        let outOfRange = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 99, original: "x", replacement: "y",
            personId: UUID(), similarity: 0.9
        )
        do {
            try await fixture.transcripts.applyTextCorrections(
                segmentId: fixture.segmentId, text: "не должно примениться", corrections: [valid, outOfRange]
            )
            XCTFail("ожидался constraintViolation")
        } catch let error as StorageError {
            guard case .constraintViolation = error else { return XCTFail("получено \(error)") }
        }
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, fixture.originalText, "text не изменился — валидация до записи")
        XCTAssertEqual(row.segment.words, fixture.words, "words_json не тронут — включая годную первую правку")
        XCTAssertNil(row.segment.textOriginal, "text_original не тронут")
        XCTAssertFalse(row.isUserEdited, "is_user_edited не тронут")
    }

    // MARK: - Правило 2 (text/text_original сегмента) вместе с непустым corrections

    func test_inv32_appliesTextAndWordCorrectionsTogetherInOneCall() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)
        let correction = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "привет", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )

        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл Иван", corrections: [correction]
        )
        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл Иванов", corrections: []
        )

        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, "Билл Иванов", "второй вызов переписывает text")
        XCTAssertEqual(row.segment.textOriginal, fixture.originalText,
                       "text_original — от первого вызова, второй его не переписывает")
        XCTAssertEqual(row.segment.words[1].text, "Иван", "правка слова из первого вызова сохранена")
        XCTAssertEqual(row.segment.words[1].original, "привет")
    }

    /// К96 (перечень MEE-189, дельта Х): та же атомарность, чужой `segmentId` вместо
    /// диапазона `wordIndex` — все четыре поля строки не тронуты.
    func test_k96_constraintViolationForMismatchedSegmentIdLeavesAllFourFieldsUntouched() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)
        let correction = TextCorrection(
            segmentId: fixture.segmentId + 1, wordIndex: 0, original: "x", replacement: "y",
            personId: UUID(), similarity: 0.9
        )
        do {
            try await fixture.transcripts.applyTextCorrections(
                segmentId: fixture.segmentId, text: "не должно примениться", corrections: [correction]
            )
            XCTFail("ожидался constraintViolation")
        } catch let error as StorageError {
            guard case .constraintViolation = error else { return XCTFail("получено \(error)") }
        }
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, fixture.originalText, "text не тронут")
        XCTAssertNil(row.segment.textOriginal, "text_original не тронут")
        XCTAssertEqual(row.segment.words, fixture.words, "words_json не тронут целиком")
        XCTAssertFalse(row.isUserEdited, "is_user_edited не тронут")
    }

    // MARK: - notFound

    func test_inv32_notFoundForMissingSegmentId() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let transcripts = temp.database.transcriptRepository()
        do {
            try await transcripts.applyTextCorrections(segmentId: 404, text: "нет", corrections: [])
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound(entity: "Segment", id: "404"))
        }
    }

    /// К98 (перечень MEE-189, дельта Х): несуществующий `segmentId` РЯДОМ с фикстурным
    /// сегментом — не в пустой базе, как выше, — и фикстура после отказа не тронута.
    func test_k98_notFoundForMissingSegmentIdLeavesFixtureSegmentUnchanged() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)
        let missingSegmentId = fixture.segmentId + 999

        do {
            try await fixture.transcripts.applyTextCorrections(
                segmentId: missingSegmentId, text: "не должно примениться", corrections: []
            )
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound(entity: "Segment", id: String(missingSegmentId)))
        }

        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, fixture.originalText, "фикстура не изменилась")
        XCTAssertNil(row.segment.textOriginal)
        XCTAssertEqual(row.segment.words, fixture.words)
        XCTAssertFalse(row.isUserEdited)
    }
}
