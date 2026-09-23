//  PortsErrorDictionaryTests — К27, К28 перечня MEE-189 (сквозные, все восемь
//  портов §5 + JobRepository), владелец: DEV-2.
//
//  К27: читающие методы на ОТСУТСТВУЮЩЕЙ сущности отдают nil/пустую коллекцию,
//  не бросают ни `notFound`, ни `io`. К28: семь пишущих методов на несуществующей
//  строке бросают `notFound` дословно по словарю — и ни один метод вне этой
//  семёрки `notFound` не бросает ни на одном входе К27.

import XCTest
import DomainCore
@testable import Storage

final class PortsErrorDictionaryTests: StorageAsyncTestCase {

    private struct Repositories {
        let meetings: MeetingRepository
        let recordings: RecordingRepository
        let transcripts: TranscriptRepository
        let persons: PersonRepository
        let speakerProfiles: SpeakerProfileRepository
        let connectors: ConnectorRepository
        let outputs: MeetingOutputRepository
        let settings: SettingsRepository
        let jobs: JobRepository
    }

    private func makeRepositories() throws -> (StorageTestSupport.TemporaryDatabase, Repositories) {
        let temp = try StorageTestSupport.makeDatabase()
        let layout = FileLayout(root: temp.directory)
        let repositories = Repositories(
            meetings: temp.database.meetingRepository(),
            recordings: temp.database.recordingRepository(fileLayout: layout),
            transcripts: temp.database.transcriptRepository(),
            persons: temp.database.personRepository(),
            speakerProfiles: temp.database.speakerProfileRepository(),
            connectors: temp.database.connectorRepository(),
            outputs: temp.database.meetingOutputRepository(),
            settings: temp.database.settingsRepository(),
            jobs: temp.database.jobRepository()
        )
        return (temp, repositories)
    }

    // MARK: - К27 (nil/пустая коллекция на отсутствующей сущности)

    func testK27_meetingPortReadsOnAbsentEntity() async throws {
        let (temp, repos) = try makeRepositories()
        defer { StorageTestSupport.cleanup(temp) }
        let missing = UUID()
        let dedupKey = DedupKey.icalUid("absent", startEpochSeconds: 0)
        try await Self.assertNilNotThrowing(try await repos.meetings.meeting(id: missing))
        try await Self.assertNilNotThrowing(try await repos.meetings.meeting(dedupKey: dedupKey))
        try await Self.assertEmptyNotThrowing(
            try await repos.meetings.meetings(from: TestFixtures.epoch, to: TestFixtures.epoch)
        )
    }

    func testK27_personPortReadsOnAbsentEntity() async throws {
        let (temp, repos) = try makeRepositories()
        defer { StorageTestSupport.cleanup(temp) }
        try await Self.assertNilNotThrowing(try await repos.persons.person(id: UUID()))
        try await Self.assertNilNotThrowing(try await repos.persons.person(email: "absent@example.com"))
        try await Self.assertEmptyNotThrowing(try await repos.persons.persons(ids: [UUID()]))
        try await Self.assertNilNotThrowing(try await repos.persons.me())
        try await Self.assertEmptyNotThrowing(try await repos.persons.nameForms(personIds: [UUID()]))
    }

    func testK27_recordingPortReadsOnAbsentEntity() async throws {
        let (temp, repos) = try makeRepositories()
        defer { StorageTestSupport.cleanup(temp) }
        try await Self.assertNilNotThrowing(try await repos.recordings.recording(id: UUID()))
        try await Self.assertEmptyNotThrowing(try await repos.recordings.recordings(meetingId: UUID()))
        try await Self.assertEmptyNotThrowing(try await repos.recordings.unfinalized())
        try await Self.assertEmptyNotThrowing(try await repos.recordings.adHoc())
    }

    func testK27_transcriptPortReadsOnAbsentEntity() async throws {
        let (temp, repos) = try makeRepositories()
        defer { StorageTestSupport.cleanup(temp) }
        try await Self.assertEmptyNotThrowing(try await repos.transcripts.headers(recordingId: UUID()))
        try await Self.assertNilNotThrowing(try await repos.transcripts.latest(recordingId: UUID()))
        try await Self.assertNilNotThrowing(try await repos.transcripts.transcript(id: UUID()))
        try await Self.assertEmptyNotThrowing(try await repos.transcripts.segments(transcriptId: UUID()))
        try await Self.assertEmptyNotThrowing(try await repos.transcripts.search(query: "absent", limit: 10, offset: 0))
    }

    func testK27_speakerProfileAndConnectorAndOutputAndSettingReadsOnAbsentEntity() async throws {
        let (temp, repos) = try makeRepositories()
        defer { StorageTestSupport.cleanup(temp) }
        try await Self.assertNilNotThrowing(
            try await repos.speakerProfiles.profile(personId: UUID(), modelVersion: "1.0")
        )
        try await Self.assertEmptyNotThrowing(
            try await repos.speakerProfiles.profiles(personIds: [UUID()], modelVersion: "1.0")
        )
        try await Self.assertEmptyNotThrowing(try await repos.connectors.all())
        try await Self.assertEmptyNotThrowing(try await repos.outputs.outputs(meetingId: UUID()))
        try await Self.assertNilNotThrowing(try await repos.settings.value(forKey: "absent-key"))
    }

    func testK27_jobPortReadsOnAbsentEntity() async throws {
        let (temp, repos) = try makeRepositories()
        defer { StorageTestSupport.cleanup(temp) }
        try await Self.assertNilNotThrowing(try await repos.jobs.job(id: UUID()))
        try await Self.assertNilNotThrowing(try await repos.jobs.activeJob(dedupKey: "absent"))
        let listing = try await repos.jobs.jobs(status: .pending)
        XCTAssertTrue(listing.jobs.isEmpty)
        XCTAssertTrue(listing.unreadable.isEmpty)
        try await Self.assertNilNotThrowing(
            try await repos.jobs.claimNext(
                types: [.transcode], excluding: [], now: TestFixtures.epoch, leaseSeconds: 60
            )
        )
        try await Self.assertEmptyNotThrowing(try await repos.jobs.reclaimExpiredLeases(now: TestFixtures.epoch))
    }

    private static func assertNilNotThrowing<T>(
        _ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let value = try await expression()
        XCTAssertNil(value, file: file, line: line)
    }

    private static func assertEmptyNotThrowing<T: Collection>(
        _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let value = try await expression()
        XCTAssertTrue(value.isEmpty, file: file, line: line)
    }

    // MARK: - К28 (semь методов бросают notFound; вне них — никогда)

    func testK28_sevenMethodsThrowNotFoundOnMissingRow() async throws {
        let (temp, repos) = try makeRepositories()
        defer { StorageTestSupport.cleanup(temp) }
        try await Self.assertNotFound(try await repos.meetings.setStatus(.recording, meetingId: UUID()))
        try await Self.assertNotFound(try await repos.persons.rename(personId: UUID(), displayName: "x"))
        try await Self.assertNotFound(try await repos.persons.setMe(personId: UUID()))
        try await Self.assertNotFound(try await repos.connectors.setCursor("c", connectorId: "absent-connector"))
        try await Self.assertNotFound(
            try await repos.connectors.setSyncOutcome(
                at: TestFixtures.epoch, error: nil, connectorId: "absent-connector"
            )
        )
        try await Self.assertNotFound(try await repos.outputs.markUserEdited(outputId: UUID(), contentMarkdown: "x"))
        try await Self.assertNotFound(
            try await repos.transcripts.updateSegmentText(segmentId: -1, text: "x", isUserEdited: true)
        )
    }

    private static func assertNotFound(
        _ expression: @autoclosure () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        do {
            try await expression()
            XCTFail("ожидался notFound", file: file, line: line)
        } catch let error as StorageError {
            guard case .notFound = error else {
                XCTFail("ожидался notFound, получено \(error)", file: file, line: line); return
            }
        }
    }
}
