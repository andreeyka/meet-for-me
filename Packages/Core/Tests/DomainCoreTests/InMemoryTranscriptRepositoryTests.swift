//  MEE-290: `InMemoryTranscriptRepository` — фейк `TranscriptRepository` C-010,
//  §«Фейк для тестов». Вынесен в свой файл из `InMemoryRepositoriesTests`: тело одного
//  тестового класса иначе перерастает предел `type_body_length`, а расширение XCTestCase
//  на Linux не даёт гарантии обнаружения тестов — второй класс её даёт.
//
//  Исполнимые здесь инварианты C-010: 12 (пара `recording_id`/`file_index` и счёт от единицы),
//  17 (правка человека не перезаписывается, и молча), 18 (порядок по `rank`, `limit == 0`),
//  20 (`notFound` бросает только метод, обязанный изменить существующую строку).
//
//  ГРАНИЦА НАЗВАНА: держимые инварианты суть УСТРОЙСТВО фейка, а не их проверка.

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryTranscriptRepositoryTests: XCTestCase {

    // MARK: - Транскрипты: инварианты 12, 17, 18 и детерминированный идентификатор

    func test_mee290_transcriptRepository_assignsFileIndexFromOne() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let first = try await repositories.transcripts.save(try transcript(for: recordingId))
        let second = try await repositories.transcripts.save(try transcript(for: recordingId))
        let foreign = try await repositories.transcripts.save(
            try transcript(for: RecordingManifestFixtures.micOnly.recordingId)
        )

        XCTAssertEqual(first.fileIndex, 1, "первый файл записи — transcript.v1.json")
        XCTAssertEqual(second.fileIndex, 2)
        XCTAssertEqual(foreign.fileIndex, 1, "счёт ведётся по записи, а не по хранилищу")
        XCTAssertNotEqual(first.id, second.id, "идентификаторы различны")
        let latest = try await repositories.transcripts.latest(recordingId: recordingId)
        XCTAssertEqual(latest?.id, second.id)
    }

    func test_mee290_transcriptRepository_deterministicIdIsStableAndDistinct() {
        XCTAssertEqual(
            InMemoryTranscriptRepository.deterministicId(1),
            InMemoryTranscriptRepository.deterministicId(1),
            "один номер — один идентификатор"
        )
        XCTAssertNotEqual(
            InMemoryTranscriptRepository.deterministicId(1),
            InMemoryTranscriptRepository.deterministicId(2)
        )
        XCTAssertEqual(
            InMemoryTranscriptRepository.deterministicId(7).uuidString.lowercased(),
            "00000000-0000-0000-0000-000000000007",
            "форма названа целиком — ветвь `?? UUID()` на этом входе не срабатывает"
        )
    }

    /// Инвариант 17: строка с `isUserEdited == true` пропускается МОЛЧА, а не отказом.
    func test_mee290_transcriptRepository_attributionSkipsUserEditedSilently() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let header = try await repositories.transcripts.save(try transcript(for: recordingId))
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        let target = try XCTUnwrap(rows.first)
        XCTAssertFalse(target.isUserEdited, "вектор непустоты: строка правкой человека ещё не помечена")

        let personId = UUID()
        let update = SegmentAttributionUpdate(
            segmentId: target.id, personId: personId, speakerConfidence: 0.9, attributionSource: .voiceProfile
        )
        try await repositories.transcripts.updateAttribution([update])
        let afterFirst = try await repositories.transcripts.segments(transcriptId: header.id)
        XCTAssertEqual(afterFirst.first?.personId, personId, "непомеченная строка правится")

        // Помечаем правкой человека и повторяем — изменение обязано не дойти, и без отказа.
        try await repositories.transcripts.updateSegmentText(
            segmentId: target.id, text: afterFirst.first?.segment.text ?? "", isUserEdited: true
        )
        let second = SegmentAttributionUpdate(
            segmentId: target.id, personId: UUID(), speakerConfidence: 0.1, attributionSource: .user
        )
        try await repositories.transcripts.updateAttribution([second])
        let afterSecond = try await repositories.transcripts.segments(transcriptId: header.id)
        XCTAssertEqual(afterSecond.first?.personId, personId, "правка человека не перезаписана")
        XCTAssertEqual(afterSecond.first?.attributionSource, AttributionSource.voiceProfile)
    }

    /// Инвариант 18: порядок по возрастанию `rank`; `limit == 0` — пустой массив.
    func test_mee290_transcriptRepository_searchIsSubstringOrderedByRank() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        _ = try await repositories.transcripts.save(try transcript(for: recordingId))

        let hits = try await repositories.transcripts.search(query: "слово", limit: 10, offset: 0)
        XCTAssertEqual(hits.count, 2, "вектор непустоты: подстрока нашлась дважды")
        XCTAssertEqual(hits.map(\.rank), hits.map(\.rank).sorted(), "по возрастанию rank")
        XCTAssertTrue(hits.allSatisfy { $0.snippet.contains("<b>слово</b>") }, "маркеры подсветки стоят")

        let zeroLimit = try await repositories.transcripts.search(query: "слово", limit: 0, offset: 0)
        XCTAssertEqual(zeroLimit, [], "limit == 0 — пустой массив")
        let offset = try await repositories.transcripts.search(query: "слово", limit: 10, offset: 1)
        XCTAssertEqual(offset.count, 1, "смещение отсекает первую")
        let miss = try await repositories.transcripts.search(query: "нетакого", limit: 10, offset: 0)
        XCTAssertEqual(miss, [], "подстроки нет — совпадений нет")
    }

    func test_mee290_transcriptRepository_updateSegmentTextThrowsNotFound() async throws {
        let repositories = InMemoryRepositories()
        do {
            try await repositories.transcripts.updateSegmentText(segmentId: 404, text: "нет", isUserEdited: true)
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound(entity: "segments", id: "404"))
        }
    }

    // MARK: - Оснастка

    /// Транскрипт с двумя сегментами, несущими искомую подстроку, и одним без неё.
    private func transcript(for recordingId: UUID) throws -> Transcript {
        try Transcript(
            recordingId: recordingId,
            language: "ru",
            engine: "gigaam",
            modelVersion: "v2",
            createdAt: Date(timeIntervalSince1970: 1_789_120_800),
            segments: [
                try segment(startMs: 0, endMs: 1_000, text: "первое слово здесь"),
                try segment(startMs: 1_000, endMs: 2_000, text: "второе слово тоже"),
                try segment(startMs: 2_000, endMs: 3_000, text: "третий без совпадения")
            ],
            speakers: []
        )
    }

    private func segment(startMs: Int, endMs: Int, text: String) throws -> Transcript.Segment {
        try Transcript.Segment(
            startMs: startMs,
            endMs: endMs,
            channel: .mic,
            speakerCluster: nil,
            text: text,
            textOriginal: nil,
            textConfidence: nil,
            words: []
        )
    }
}
