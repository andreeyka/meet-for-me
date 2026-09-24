//  TranscriptRepositorySearchTests — К23 перечня MEE-189 (группа D), владелец: DEV-2.

import XCTest
import DomainCore
@testable import Storage

final class TranscriptRepositorySearchTests: StorageAsyncTestCase {

    /// К23, инвариант 18: `limit`/`offset` режут результат страницами без
    /// пересечений, порядок — по `rank` (bm25, меньше значит релевантнее),
    /// `limit = 0` даёт пустой массив, `snippet` несёт разметку `<b>…</b>`.
    func testK23_searchPaginatesAndRanksAndSnippets() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))

        let needle = "widget"
        let segments = try (0..<8).map { index in
            try TestFixtures.segment(startMs: index * 1_000, endMs: index * 1_000 + 500, text: "\(needle) row \(index)")
        }
        _ = try await transcripts.save(try TestFixtures.transcript(recordingId: recordingId, segments: segments))

        let firstPage = try await transcripts.search(query: needle, limit: 5, offset: 0)
        XCTAssertEqual(firstPage.count, 5)
        let ranks = firstPage.map(\.rank)
        XCTAssertEqual(ranks, ranks.sorted(), "rank неубывает — bm25, меньше значит релевантнее")

        let secondPage = try await transcripts.search(query: needle, limit: 5, offset: 5)
        XCTAssertEqual(secondPage.count, 3, "восемь строк минус первые пять")

        let firstIds = Set(firstPage.map(\.segmentId))
        let secondIds = Set(secondPage.map(\.segmentId))
        XCTAssertTrue(firstIds.isDisjoint(with: secondIds), "страницы не пересекаются")
        XCTAssertEqual(firstIds.union(secondIds).count, 8, "обе страницы вместе покрывают все совпадения")

        let empty = try await transcripts.search(query: needle, limit: 0, offset: 0)
        XCTAssertTrue(empty.isEmpty, "limit = 0 — пустой массив средствами SQL")

        let hit = try XCTUnwrap(firstPage.first)
        XCTAssertTrue(hit.snippet.contains("<b>"), "snippet несёт разметку совпадения")
        XCTAssertTrue(hit.snippet.contains("</b>"))
    }
}
