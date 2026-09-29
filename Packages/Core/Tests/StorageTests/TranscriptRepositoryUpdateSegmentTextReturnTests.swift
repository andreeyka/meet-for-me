//  TranscriptRepositoryUpdateSegmentTextReturnTests — C-010 v26, инвариант 35 (IR-139,
//  MEE-445): `updateSegmentText` возвращает `transcriptId` изменённой строки — то же
//  значение, что `SegmentRow.transcriptId` при чтении. Владелец: DEV-2.

import XCTest
import DomainCore
@testable import Storage

final class TranscriptRepositoryUpdateSegmentTextReturnTests: StorageAsyncTestCase {

    /// Два транскрипта одной записи: возврат — транскрипт именно изменённой строки, а не
    /// первый попавшийся и не последний сохранённый.
    func test_mee445_updateSegmentTextReturnsTranscriptIdOfEditedRow() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let first = try await transcripts.save(try TestFixtures.transcript(
            recordingId: recordingId, segments: try TestFixtures.threeDistinctSegments(prefix: "first")
        ))
        let second = try await transcripts.save(try TestFixtures.transcript(
            recordingId: recordingId, segments: try TestFixtures.threeDistinctSegments(prefix: "second")
        ))

        let firstRows = try await transcripts.segments(transcriptId: first.id)
        let returnedForFirst = try await transcripts.updateSegmentText(
            segmentId: firstRows[1].id, text: "first edited", isUserEdited: true
        )
        XCTAssertEqual(returnedForFirst, firstRows[1].transcriptId)
        XCTAssertEqual(returnedForFirst, first.id)

        let secondRows = try await transcripts.segments(transcriptId: second.id)
        let returnedForSecond = try await transcripts.updateSegmentText(
            segmentId: secondRows[0].id, text: "second edited", isUserEdited: false
        )
        XCTAssertEqual(returnedForSecond, secondRows[0].transcriptId)
        XCTAssertEqual(returnedForSecond, second.id)

        let reread = try await transcripts.segments(transcriptId: first.id)
        XCTAssertEqual(reread[1].segment.text, "first edited", "запись прошла, возврат её не заменил")
        XCTAssertTrue(reread[1].isUserEdited)
    }

    /// Несуществующий `segmentId` — тот же `notFound(segment, id)`, что до v26: новый
    /// `SELECT` не превратил отказ в `nil`-возврат или в другой код.
    func test_mee445_updateSegmentTextOnUnknownSegmentStillThrowsNotFound() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let transcripts = temp.database.transcriptRepository()

        do {
            try await transcripts.updateSegmentText(segmentId: 404, text: "x", isUserEdited: true)
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            guard case .notFound(let entity, let id) = error else {
                return XCTFail("ожидался notFound, получено \(error)")
            }
            XCTAssertEqual(entity, StorageEntity.segment)
            XCTAssertEqual(id, "404")
        }
    }
}
