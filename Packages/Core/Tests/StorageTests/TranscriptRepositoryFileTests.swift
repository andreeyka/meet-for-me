//  TranscriptRepositoryFileTests — К16, К20, К22 перечня MEE-189 (группы B и D),
//  владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class TranscriptRepositoryFileTests: StorageAsyncTestCase {

    // MARK: - К16

    func testK16_fileIndexIsMaxPlusOneAndUniquePerRecording() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))

        let oneSegment = {
            try TestFixtures.transcript(
                recordingId: recordingId, segments: [try TestFixtures.segment(startMs: 0, endMs: 10, text: "x")]
            )
        }
        let first = try await transcripts.save(try oneSegment())
        let second = try await transcripts.save(try oneSegment())
        let third = try await transcripts.save(try oneSegment())
        XCTAssertEqual([first.fileIndex, second.fileIndex, third.fileIndex], [1, 2, 3])

        // (ii) FileLayout.transcriptURL(dir, index: N) для N из fileIndex.
        let url = layout.transcriptURL(recordingId.uuidString, index: third.fileIndex)
        XCTAssertTrue(url.path.hasSuffix("transcript.v3.json"))

        // Четвёртая вставка через Ш7 с занятой парой (recording_id, file_index) — отвергнута.
        XCTAssertThrowsError(
            try temp.database.rawWrite { db in
                try db.execute(
                    sql: """
                    INSERT INTO transcripts (id, recording_id, file_index, engine, model_version, language, created_at)
                    VALUES (?, ?, 3, 'e', 'm', 'en', 0)
                    """,
                    arguments: [UUID().uuidString, recordingId.uuidString]
                )
            }
        )
    }

    // MARK: - К20

    func testK20_updateAttributionAndUpdateSegmentTextDoNotTouchTranscriptFile() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()
        let persons = temp.database.personRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let segments = try TestFixtures.threeDistinctSegments(prefix: "seg")
        let header = try await transcripts.save(
            try TestFixtures.transcript(recordingId: recordingId, segments: segments)
        )
        let personId = try await persons.upsert(displayName: "K20 Person", emails: ["k20@example.com"])

        let directory = layout.recordingDirectory(recordingId.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = layout.transcriptURL(recordingId.uuidString, index: header.fileIndex)
        let fixtureBytes = Data("original-transcript-bytes".utf8)
        try fixtureBytes.write(to: fileURL)

        let rows = try await transcripts.segments(transcriptId: header.id)
        try await transcripts.updateAttribution(rows.map {
            SegmentAttributionUpdate(
                segmentId: $0.id, personId: personId, speakerConfidence: 0.9, attributionSource: .voiceProfile
            )
        })
        try await transcripts.updateSegmentText(segmentId: rows[1].id, text: "edited", isUserEdited: true)

        let afterBytes = try Data(contentsOf: fileURL)
        XCTAssertEqual(afterBytes, fixtureBytes, "transcript.v<N>.json не тронут")

        let updatedRows = try await transcripts.segments(transcriptId: header.id)
        for row in rows {
            XCTAssertEqual(
                updatedRows.first { $0.id == row.id }?.attributionSource, .voiceProfile,
                "атрибуция применена на всех трёх сегментах, включая тот, чей текст правится следом"
            )
        }
        XCTAssertEqual(updatedRows.first { $0.id == rows[1].id }?.segment.text, "edited")
    }

    // MARK: - К22

    func testK22_updateAttributionSkipsUserEditedRowSilently() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()
        let persons = temp.database.personRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let segments = try TestFixtures.threeDistinctSegments(prefix: "seg")
        let header = try await transcripts.save(
            try TestFixtures.transcript(recordingId: recordingId, segments: segments)
        )
        let rows = try await transcripts.segments(transcriptId: header.id)
        let personId = try await persons.upsert(displayName: "K22 Person", emails: ["k22@example.com"])

        try await transcripts.updateSegmentText(segmentId: rows[1].id, text: "user text", isUserEdited: true)

        let updates = rows.map {
            SegmentAttributionUpdate(
                segmentId: $0.id, personId: personId, speakerConfidence: 0.5, attributionSource: .oneOnOne
            )
        }
        try await transcripts.updateAttribution(updates)

        let after = try await transcripts.segments(transcriptId: header.id)
        let protectedRow = try XCTUnwrap(after.first { $0.id == rows[1].id })
        XCTAssertNil(protectedRow.personId, "правка пользователя не тронута ни одной колонкой")
        XCTAssertNil(protectedRow.speakerConfidence)
        XCTAssertNil(protectedRow.attributionSource)
        XCTAssertEqual(protectedRow.segment.text, "user text")

        for row in after where row.id != rows[1].id {
            XCTAssertEqual(row.attributionSource, .oneOnOne, "остальные обновлены")
        }
    }
}
