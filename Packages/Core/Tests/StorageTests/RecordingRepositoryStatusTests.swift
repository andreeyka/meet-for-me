//  RecordingRepositoryStatusTests — К85, К86 перечня MEE-189 (инварианты 28,
//  29 C-010), владелец: DEV-2.

import XCTest
import DomainCore
@testable import Storage

final class RecordingRepositoryStatusTests: StorageAsyncTestCase {

    // MARK: - К85 (инвариант 28): unfinalized() — три статуса из четырёх

    func testK85_unfinalizedExcludesOnlyFinalized() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let repository = temp.database.recordingRepository(fileLayout: layout)

        let byStatus = try await Self.saveOnePerStatus(repository)

        let unfinalized = try await repository.unfinalized()
        let unfinalizedIds = Set(unfinalized.map(\.manifest.recordingId))
        let nonFinalized: [RecordingStatus] = [.recording, .stopping, .failed]
        let expectedIds = Set(nonFinalized.map { byStatus[$0]! })
        XCTAssertEqual(unfinalizedIds, expectedIds, "ровно три статуса из четырёх, не .finalized")
        XCTAssertFalse(unfinalizedIds.contains(byStatus[.finalized]!), "запись .finalized не входит")
    }

    private static func saveOnePerStatus(
        _ repository: RecordingRepository
    ) async throws -> [RecordingStatus: UUID] {
        var result: [RecordingStatus: UUID] = [:]
        for status: RecordingStatus in [.recording, .stopping, .failed, .finalized] {
            let recordingId = UUID()
            try await repository.save(RecordingRecord(
                manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: status
            ))
            result[status] = recordingId
        }
        return result
    }

    // MARK: - К86 (инвариант 29): adHoc() — три пути одновременно

    func testK86_adHocReturnsAllThreeVectorsRegardlessOfStatus() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        let meetings = temp.database.meetingRepository()

        // (i) ad-hoc с самого начала: meetingId == nil, статус .recording.
        let adHocFromStart = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: adHocFromStart, meetingId: nil),
            status: .recording
        ))

        // (ii) сценарий К11: встреча с одной записью, delete(meetingIds:) —
        // каскад обнулил meeting_id, manifest.meetingId по-прежнему хранит
        // старый id; статус нетерминальный.
        let orphanedByDeletion = UUID()
        let meeting = try TestFixtures.meetingEvent(externalId: "ext-k86-orphaned")
        try await meetings.save(MeetingRecord(event: meeting, dedupKey: nil, status: .scheduled, sources: []))
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: orphanedByDeletion, meetingId: meeting.id),
            status: .recording
        ))
        try await meetings.delete(meetingIds: [meeting.id])

        // (iii) ad-hoc И уже финализированная: meetingId == nil, статус .finalized.
        let adHocFinalized = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: adHocFinalized, meetingId: nil),
            status: .finalized
        ))

        let adHoc = try await recordings.adHoc()
        let adHocIds = Set(adHoc.map(\.manifest.recordingId))
        XCTAssertEqual(
            adHocIds, Set([adHocFromStart, orphanedByDeletion, adHocFinalized]),
            "все три вектора сразу, независимо от status, включая терминальный .finalized"
        )
    }
}
