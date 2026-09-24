//  InMemoryTextCorrectionsTests — C-010 v19, инвариант 32 (IR-129, MEE-388),
//  владелец: DEV-2. Номера — по инварианту (`test_inv32_*`): дельта MEE-189 для этого
//  метода ещё не выпущена аналитиком. Вынесено в свой файл — тот же приём, что у
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

    func test_inv32_appliesCorrectionWhenWordOriginalNotYetSet() async throws {
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

    // MARK: - constraintViolation — строка не меняется целиком

    func test_inv32_constraintViolationForWordIndexOutOfRange() async throws {
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

    func test_inv32_constraintViolationForMismatchedSegmentId() async throws {
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
        XCTAssertEqual(row.segment.text, fixture.originalText)
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
}
