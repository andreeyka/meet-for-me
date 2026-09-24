//  InMemoryTextCorrectionsTests — C-010 v19, инвариант 32 (IR-129, MEE-388),
//  владелец: DEV-2. Тесты без своего критерия перечня MEE-189 остаются `test_inv32_*`
//  (по инварианту); К95/К96/К98 (дельта Х MEE-189, усилены находками QA — MEE-398)
//  названы своим номером. Вынесено в свой файл — тот же приём, что у
//  `InMemoryTranscriptRepositoryTests` (`type_body_length`/обнаружение тестов на Linux).

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryTextCorrectionsTests: XCTestCase {

    // MARK: - Оснастка

    private struct Fixture {
        let repositories: InMemoryRepositories
        let segmentId: Int64
        let originalText: String
        let words: [Transcript.Word]

        func row() async throws -> SegmentRow {
            let rows = try await repositories.transcripts.segments(transcriptId: try transcriptId())
            guard let match = rows.first(where: { $0.id == segmentId }) else {
                throw StorageError.notFound(entity: "Segment", id: String(segmentId))
            }
            return match
        }

        private func transcriptId() async throws -> UUID {
            let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
            let header = try await repositories.transcripts.latest(recordingId: recordingId)
            return try XCTUnwrap(header?.id)
        }
    }

    /// Сегмент с двумя словами: у первого `.original` уже записан (симулирует более
    /// раннюю правку), у второго — ещё нет.
    private func makeFixture() async throws -> Fixture {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let words = [
            try Transcript.Word(startMs: 0, endMs: 400, text: "Билл", confidence: nil, original: "билл"),
            try Transcript.Word(startMs: 400, endMs: 800, text: "привет", confidence: nil, original: nil)
        ]
        let segment = try Transcript.Segment(
            startMs: 0, endMs: 800, channel: .mic, speakerCluster: nil,
            text: "Билл привет", textOriginal: nil, textConfidence: nil, words: words
        )
        let transcript = try Transcript(
            recordingId: recordingId, language: "ru", engine: "engine", modelVersion: "1.0",
            createdAt: Date(timeIntervalSince1970: 0), segments: [segment], speakers: []
        )
        let header = try await repositories.transcripts.save(transcript)
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        let row = try XCTUnwrap(rows.first)
        return Fixture(
            repositories: repositories, segmentId: row.id, originalText: "Билл привет", words: words
        )
    }

    // MARK: - text / text_original / is_user_edited

    func test_inv32_writesTextAndTextOriginalWhenNull() async throws {
        let fixture = try await makeFixture()
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл, привет!", corrections: []
        )
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, "Билл, привет!")
        XCTAssertEqual(row.segment.textOriginal, fixture.originalText, "прежний text ушёл в text_original")
        XCTAssertFalse(row.isUserEdited)
    }

    func test_inv32_doesNotOverwriteExistingTextOriginal() async throws {
        let fixture = try await makeFixture()
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "первая правка", corrections: []
        )
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "вторая правка", corrections: []
        )
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, "вторая правка")
        XCTAssertEqual(row.segment.textOriginal, fixture.originalText, "text_original не переписан второй раз")
    }

    // MARK: - words[i]

    /// К95 (перечень MEE-189, дельта Х): правило «только если ещё не записано» — по КАЖДОМУ
    /// слову отдельно, соседнее слово вне правки не трогается ни в одном поле.
    func test_k95_appliesCorrectionWhenWordOriginalNotYetSet() async throws {
        let fixture = try await makeFixture()
        let correction = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "привет", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл Иван", corrections: [correction]
        )
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.words[1].text, "Иван")
        XCTAssertEqual(row.segment.words[1].original, "привет")
        XCTAssertEqual(row.segment.words[0].text, "Билл", "слово вне правки не тронуто")
        XCTAssertEqual(row.segment.words[0].original, "билл", "соседнее слово: .original тоже не тронут")
    }

    /// К95 (перечень MEE-189, дельта Х): ДВА настоящих вызова, оба правят одно и то же
    /// слово разными `replacement` — не одна правка внутри одного вызова, как выше.
    func test_k95_secondRealCallToSameWordOverwritesTextButPreservesOriginalFromFirstCall() async throws {
        let fixture = try await makeFixture()
        let first = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "привет", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл Иван", corrections: [first]
        )
        // Второй вызов задаёт другой `original` ("ИНАЧЕ") — если бы `.original`
        // переписывался заново, тест поймал бы это по значению из ВТОРОГО вызова.
        let second = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "ИНАЧЕ", replacement: "Пётр",
            personId: UUID(), similarity: 0.9
        )
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл Пётр", corrections: [second]
        )
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.words[1].text, "Пётр", "второй настоящий вызов переписывает text снова")
        XCTAssertEqual(row.segment.words[1].original, "привет", "original сохранён от первого вызова, не от второго")
    }

    /// РП, 24.09 20:45 UTC: правило 1 — `words[i].text` пишется для КАЖДОЙ правки; оговорка
    /// «только если ещё не записано» относится ТОЛЬКО к `.original` (та же пара, что
    /// `text`/`textOriginal` сегмента), не к `text` слова.
    func test_inv32_doesNotOverwriteWordWhenOriginalAlreadySet() async throws {
        let fixture = try await makeFixture()
        let correction = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 0, original: "другое", replacement: "Уильям",
            personId: UUID(), similarity: 0.9
        )
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл привет", corrections: [correction]
        )
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.words[0].text, "Уильям", "text слова переписан — правило 1 действует всегда")
        XCTAssertEqual(row.segment.words[0].original, "билл", "прежний .original не переписан")
    }

    func test_inv32_emptyCorrectionsLeavesWordsUntouched() async throws {
        let fixture = try await makeFixture()
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "новый текст", corrections: []
        )
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.words, fixture.words, "words не тронуты пустым corrections")
    }

    // MARK: - is_user_edited = 1 — молча не трогается

    func test_inv32_skipsRowWithIsUserEditedSilently() async throws {
        let fixture = try await makeFixture()
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: fixture.segmentId, text: "правка человека", isUserEdited: true
        )
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "не должно примениться", corrections: []
        )
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, "правка человека", "строка не тронута")
        XCTAssertTrue(row.isUserEdited)
    }

    /// РП, 24.09 20:57 UTC: `is_user_edited = 1` — молча не трогается ДАЖЕ с непустым
    /// `corrections` (правило 2, слово в правке) — не только с пустым, как выше. Сравнение
    /// `text_original` — с состоянием ПОСЛЕ `updateSegmentText`, не с `nil`: у фейка (в отличие
    /// от GRDB) `updateSegmentText` сам уже пишет `text_original` при первой правке — это
    /// поведение чужого метода, не предмет данного теста.
    func test_inv32_skipsRowWithIsUserEditedSilentlyEvenWithWordCorrection() async throws {
        let fixture = try await makeFixture()
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: fixture.segmentId, text: "правка человека", isUserEdited: true
        )
        let textOriginalBeforeCorrections = try await fixture.row().segment.textOriginal
        let correction = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "привет", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "не должно примениться", corrections: [correction]
        )
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, "правка человека", "text не тронут")
        XCTAssertEqual(row.segment.textOriginal, textOriginalBeforeCorrections, "text_original не тронут")
        XCTAssertEqual(row.segment.words, fixture.words, "words не тронуты — включая слово из правки")
        XCTAssertTrue(row.isUserEdited)
    }

    // MARK: - constraintViolation — строка не меняется целиком

    /// К96 (перечень MEE-189, дельта Х): атомарность отказа — все ЧЕТЫРЕ поля строки,
    /// не только `text`.
    func test_k96_constraintViolationForWordIndexOutOfRangeLeavesAllFourFieldsUntouched() async throws {
        let fixture = try await makeFixture()
        let correction = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 99, original: "x", replacement: "y",
            personId: UUID(), similarity: 0.9
        )
        do {
            try await fixture.repositories.transcripts.applyTextCorrections(
                segmentId: fixture.segmentId, text: "не должно примениться", corrections: [correction]
            )
            XCTFail("ожидался constraintViolation")
        } catch let error as StorageError {
            guard case .constraintViolation = error else { return XCTFail("получено \(error)") }
        }
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, fixture.originalText, "text не изменился — отказ до записи")
        XCTAssertNil(row.segment.textOriginal, "text_original не тронут")
        XCTAssertEqual(row.segment.words, fixture.words, "words не тронуты целиком")
        XCTAssertFalse(row.isUserEdited, "is_user_edited не тронут")
    }

    /// Смешанный вход: первая правка в диапазоне, вторая — нет. Валидация — до записи,
    /// поэтому даже первая, сама по себе годная, правка не применяется — строка не меняется
    /// НИ В ОДНОМ поле.
    func test_inv32_mixedInputSecondCorrectionOutOfRangeChangesNothing() async throws {
        let fixture = try await makeFixture()
        let valid = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "привет", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )
        let outOfRange = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 99, original: "x", replacement: "y",
            personId: UUID(), similarity: 0.9
        )
        do {
            try await fixture.repositories.transcripts.applyTextCorrections(
                segmentId: fixture.segmentId, text: "не должно примениться", corrections: [valid, outOfRange]
            )
            XCTFail("ожидался constraintViolation")
        } catch let error as StorageError {
            guard case .constraintViolation = error else { return XCTFail("получено \(error)") }
        }
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, fixture.originalText, "text не изменился — валидация до записи")
        XCTAssertEqual(row.segment.words, fixture.words, "words не тронуты — включая годную первую правку")
        XCTAssertNil(row.segment.textOriginal, "text_original не тронут")
        XCTAssertFalse(row.isUserEdited, "is_user_edited не тронут")
    }

    // MARK: - Правило 2 (text/textOriginal сегмента) вместе с непустым corrections

    func test_inv32_appliesTextAndWordCorrectionsTogetherInOneCall() async throws {
        let fixture = try await makeFixture()
        let correction = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "привет", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )
        try await fixture.repositories.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл Иван", corrections: [correction]
        )
        try await fixture.repositories.transcripts.applyTextCorrections(
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
        let fixture = try await makeFixture()
        let correction = TextCorrection(
            segmentId: fixture.segmentId + 1, wordIndex: 0, original: "x", replacement: "y",
            personId: UUID(), similarity: 0.9
        )
        do {
            try await fixture.repositories.transcripts.applyTextCorrections(
                segmentId: fixture.segmentId, text: "не должно примениться", corrections: [correction]
            )
            XCTFail("ожидался constraintViolation")
        } catch let error as StorageError {
            guard case .constraintViolation = error else { return XCTFail("получено \(error)") }
        }
        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, fixture.originalText, "text не тронут")
        XCTAssertNil(row.segment.textOriginal, "text_original не тронут")
        XCTAssertEqual(row.segment.words, fixture.words, "words не тронуты целиком")
        XCTAssertFalse(row.isUserEdited, "is_user_edited не тронут")
    }

    // MARK: - notFound

    func test_inv32_notFoundForMissingSegmentId() async throws {
        let repositories = InMemoryRepositories()
        do {
            try await repositories.transcripts.applyTextCorrections(segmentId: 404, text: "нет", corrections: [])
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound(entity: "Segment", id: "404"))
        }
    }

    /// К98 (перечень MEE-189, дельта Х): несуществующий `segmentId` РЯДОМ с фикстурным
    /// сегментом — не в пустом репозитории, как выше, — и фикстура после отказа не тронута.
    func test_k98_notFoundForMissingSegmentIdLeavesFixtureSegmentUnchanged() async throws {
        let fixture = try await makeFixture()
        let missingSegmentId = fixture.segmentId + 999
        do {
            try await fixture.repositories.transcripts.applyTextCorrections(
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
