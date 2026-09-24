//  TranscriptRepositoryCorrectionsTests — C-010 v19, инвариант 32 (IR-129, MEE-388),
//  владелец: DEV-2. Тесты без своего критерия перечня MEE-189 остаются `test_inv32_*`
//  (по инварианту); К95/К96/К98 (дельта Х MEE-189, усилены находками QA — MEE-398)
//  названы своим номером.
//
//  Секции constraintViolation/notFound — во втором файле того же класса, `extension`
//  (`TranscriptRepositoryCorrectionsTests+ConstraintAndNotFound.swift`): усиление MEE-398
//  подняло тело класса за порог `type_body_length` SwiftLint (250 строк без учёта
//  комментариев и пустых) — тот же приём, что у `InMemoryTextCorrectionsTests`.
//  `Fixture`/`makeFixture(_:)` поэтому не `private` — их зовёт и второй файл.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class TranscriptRepositoryCorrectionsTests: StorageAsyncTestCase {

    // MARK: - Оснастка

    struct Fixture {
        let transcripts: TranscriptRepository
        let transcriptId: UUID
        let segmentId: Int64
        let originalText: String
        let words: [Transcript.Word]

        func row() async throws -> SegmentRow {
            let rows = try await transcripts.segments(transcriptId: transcriptId)
            guard let match = rows.first(where: { $0.id == segmentId }) else {
                throw StorageError.notFound(entity: "Segment", id: String(segmentId))
            }
            return match
        }
    }

    /// Сегмент с двумя словами: у первого `.original` уже записан (симулирует более
    /// раннюю правку), у второго — ещё нет.
    static func makeFixture(_ temp: StorageTestSupport.TemporaryDatabase) async throws -> Fixture {
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()
        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let words = [
            try Transcript.Word(startMs: 0, endMs: 400, text: "Билл", confidence: nil, original: "билл"),
            try Transcript.Word(startMs: 400, endMs: 800, text: "привет", confidence: nil, original: nil)
        ]
        let segment = try Transcript.Segment(
            startMs: 0, endMs: 800, channel: .mic, speakerCluster: nil,
            text: "Билл привет", textOriginal: nil, textConfidence: nil, words: words
        )
        let header = try await transcripts.save(
            try TestFixtures.transcript(recordingId: recordingId, segments: [segment])
        )
        let rows = try await transcripts.segments(transcriptId: header.id)
        let row = try XCTUnwrap(rows.first)
        return Fixture(
            transcripts: transcripts, transcriptId: header.id, segmentId: row.id,
            originalText: "Билл привет", words: words
        )
    }

    // MARK: - text / text_original / is_user_edited

    func test_inv32_writesTextAndTextOriginalWhenNull() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)

        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл, привет!", corrections: []
        )

        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, "Билл, привет!")
        XCTAssertEqual(row.segment.textOriginal, fixture.originalText, "прежний text ушёл в text_original")
        XCTAssertFalse(row.isUserEdited)
    }

    func test_inv32_doesNotOverwriteExistingTextOriginal() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)

        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "первая правка", corrections: []
        )
        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "вторая правка", corrections: []
        )

        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, "вторая правка")
        XCTAssertEqual(row.segment.textOriginal, fixture.originalText, "text_original не переписан второй раз")
    }

    // MARK: - words_json[i]

    /// К95 (перечень MEE-189, дельта Х): правило «только если ещё не записано» — по КАЖДОМУ
    /// слову отдельно, соседнее слово вне правки не трогается ни в одном поле.
    func test_k95_appliesCorrectionWhenWordOriginalNotYetSet() async throws {
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

        let row = try await fixture.row()
        XCTAssertEqual(row.segment.words[1].text, "Иван")
        XCTAssertEqual(row.segment.words[1].original, "привет")
        XCTAssertEqual(row.segment.words[0].text, "Билл", "слово вне правки не тронуто")
        XCTAssertEqual(row.segment.words[0].original, "билл", "соседнее слово: .original тоже не тронут")
    }

    /// К95 (перечень MEE-189, дельта Х): ДВА настоящих вызова, оба правят одно и то же
    /// слово разными `replacement` — не одна правка внутри одного вызова, как выше.
    func test_k95_secondRealCallToSameWordOverwritesTextButPreservesOriginalFromFirstCall() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)
        let first = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "привет", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )

        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл Иван", corrections: [first]
        )
        // Второй вызов задаёт другой `original` ("ИНАЧЕ") — если бы `.original`
        // переписывался заново, тест поймал бы это по значению из ВТОРОГО вызова.
        let second = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "ИНАЧЕ", replacement: "Пётр",
            personId: UUID(), similarity: 0.9
        )
        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл Пётр", corrections: [second]
        )

        let row = try await fixture.row()
        XCTAssertEqual(row.segment.words[1].text, "Пётр", "второй настоящий вызов переписывает text снова")
        XCTAssertEqual(row.segment.words[1].original, "привет", "original сохранён от первого вызова, не от второго")
    }

    /// РП, 24.09 20:45 UTC: правило 1 — `words_json[i].text` пишется для КАЖДОЙ правки;
    /// оговорка «только если ещё не записано» относится ТОЛЬКО к `.original` (та же пара,
    /// что `text`/`text_original` сегмента), не к `text` слова.
    func test_inv32_doesNotOverwriteWordWhenOriginalAlreadySet() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)
        let correction = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 0, original: "другое", replacement: "Уильям",
            personId: UUID(), similarity: 0.9
        )

        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "Билл привет", corrections: [correction]
        )

        let row = try await fixture.row()
        XCTAssertEqual(row.segment.words[0].text, "Уильям", "text слова переписан — правило 1 действует всегда")
        XCTAssertEqual(row.segment.words[0].original, "билл", "прежний .original не переписан")
    }

    func test_inv32_emptyCorrectionsLeavesWordsUntouched() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)

        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "новый текст", corrections: []
        )

        let row = try await fixture.row()
        XCTAssertEqual(row.segment.words, fixture.words, "words_json не тронут пустым corrections")
    }

    // MARK: - is_user_edited = 1 — молча не трогается

    func test_inv32_skipsRowWithIsUserEditedSilently() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)
        try await fixture.transcripts.updateSegmentText(
            segmentId: fixture.segmentId, text: "правка человека", isUserEdited: true
        )

        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "не должно примениться", corrections: []
        )

        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, "правка человека", "строка не тронута")
        XCTAssertTrue(row.isUserEdited)
    }

    /// РП, 24.09 20:57 UTC: `is_user_edited = 1` — молча не трогается ДАЖЕ с непустым
    /// `corrections` (правило 2, слово в правке) — не только с пустым, как выше.
    /// Сравнение `text_original` — с состоянием ПОСЛЕ `updateSegmentText`, не с `nil`: то,
    /// пишет ли `updateSegmentText` сам `text_original` при первой правке, — поведение
    /// чужого метода, не предмет данного теста (см. тот же приём в фейке).
    func test_inv32_skipsRowWithIsUserEditedSilentlyEvenWithWordCorrection() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let fixture = try await Self.makeFixture(temp)
        try await fixture.transcripts.updateSegmentText(
            segmentId: fixture.segmentId, text: "правка человека", isUserEdited: true
        )
        let textOriginalBeforeCorrections = try await fixture.row().segment.textOriginal
        let correction = TextCorrection(
            segmentId: fixture.segmentId, wordIndex: 1, original: "привет", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )

        try await fixture.transcripts.applyTextCorrections(
            segmentId: fixture.segmentId, text: "не должно примениться", corrections: [correction]
        )

        let row = try await fixture.row()
        XCTAssertEqual(row.segment.text, "правка человека", "text не тронут")
        XCTAssertEqual(row.segment.textOriginal, textOriginalBeforeCorrections, "text_original не тронут")
        XCTAssertEqual(row.segment.words, fixture.words, "words_json не тронут — включая слово из правки")
        XCTAssertTrue(row.isUserEdited)
    }
}
