//  MeetingRepositoryAbsorbingTests — `save(_:absorbing:)`, C-010 v21 инвариант 33
//  (IR-133, MEE-405, MEE-407), владелец: DEV-2. Отдельный файл от `MeetingRepositoryTests
//  .swift` — тот уже держит К9/К91/К92/инв. 31 и близок к порогу `file_length`.

import XCTest
import DomainCore
@testable import Storage

final class MeetingRepositoryAbsorbingTests: StorageAsyncTestCase {

    func testAbsorbing_emptyMeetingIdsBehavesAsOrdinarySave() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let repository = temp.database.meetingRepository()

        let event = try TestFixtures.meetingEvent(externalId: "ext-abs-empty")
        try await repository.save(
            MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: []), absorbing: []
        )

        let read = try await repository.meeting(id: event.id)
        XCTAssertNotNil(read, "пустой meetingIds — эквивалент обычного save")
    }

    func testAbsorbing_meetingIdsContainingRecordEventIdThrowsConstraintViolation() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let repository = temp.database.meetingRepository()

        let event = try TestFixtures.meetingEvent(externalId: "ext-abs-self")
        let record = MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: [])
        do {
            try await repository.save(record, absorbing: [event.id])
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }
        let read = try await repository.meeting(id: event.id)
        XCTAssertNil(read, "ничего не создано")
    }

    /// Победитель УЖЕ существует (update-in-place) — перенос `recordings`/`meeting_outputs`
    /// не встречает внешнего ключа (СТРОКА `GRDBMeetingRepositoryWrite.swift`), каскад
    /// инварианта 7 уносит `meeting_sources`/`attendees` проигравшего.
    func testAbsorbing_transfersRecordingsAndOutputsToPreexistingWinnerAndDeletesLoser() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let meetingRepository = temp.database.meetingRepository()
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let outputRepository = temp.database.meetingOutputRepository()

        let winnerEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-winner")
        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-loser")
        try await meetingRepository.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let recordingId = try await Self.seedRecording(
            meetingId: loserEvent.id, layout: layout, repository: recordingRepository
        )
        let output = MeetingOutput(
            id: UUID(), meetingId: loserEvent.id, kind: .summary, engine: "e", modelVersion: "m1",
            promptVersion: "p1", contentMarkdown: "text", structuredJson: nil,
            createdAt: TestFixtures.epoch, isUserEdited: false
        )
        try await outputRepository.save(output)

        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: []),
            absorbing: [loserEvent.id]
        )

        let loserRead = try await meetingRepository.meeting(id: loserEvent.id)
        XCTAssertNil(loserRead, "проигравший удалён")

        let recording = try await recordingRepository.recording(id: recordingId)
        XCTAssertEqual(recording?.manifest.meetingId, loserEvent.id, "манифест (K87) не переписывается")
        let recordingsForWinner = try await recordingRepository.recordings(meetingId: winnerEvent.id)
        XCTAssertTrue(
            recordingsForWinner.contains { $0.manifest.recordingId == recordingId }, "запись перенесена"
        )

        let outputsForWinner = try await outputRepository.outputs(meetingId: winnerEvent.id)
        XCTAssertEqual(outputsForWinner.map(\.id), [output.id], "выдача перенесена")
        let outputsForLoser = try await outputRepository.outputs(meetingId: loserEvent.id)
        XCTAssertTrue(outputsForLoser.isEmpty)
    }

    /// Мотивация метода: победитель наследует `dedup_key` проигравшего. Проверься
    /// уникальность ДО удаления (2), это выглядело бы коллизией с самим проигравшим.
    func testAbsorbing_winnerInheritsLoserDedupKeyWithoutFalseSelfCollision() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetingRepository = temp.database.meetingRepository()

        let winnerEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-inherit-winner")
        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let sharedKey = DedupKey.icalUid("uid-inherit", startEpochSeconds: 200)
        let loserEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-inherit-loser")
        try await meetingRepository.save(
            MeetingRecord(event: loserEvent, dedupKey: sharedKey, status: .scheduled, sources: [])
        )

        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: sharedKey, status: .scheduled, sources: []),
            absorbing: [loserEvent.id]
        )

        let winnerRead = try await meetingRepository.meeting(id: winnerEvent.id)
        XCTAssertEqual(winnerRead?.dedupKey, sharedKey)
        let loserRead = try await meetingRepository.meeting(id: loserEvent.id)
        XCTAssertNil(loserRead)
    }

    /// Атомарность: отказ на шаге (3) (`dedup_key`, занятый ТРЕТЬЕЙ встречей — шаги (1)/(2)
    /// сами по себе ничего не нарушают) откатывает всю транзакцию целиком.
    func testAbsorbing_atomicRollbackOnStep3FailureTransfersNothingDeletesNothing() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let meetingRepository = temp.database.meetingRepository()
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)

        let winnerEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-atomic-winner")
        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-atomic-loser")
        try await meetingRepository.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let recordingId = try await Self.seedRecording(
            meetingId: loserEvent.id, layout: layout, repository: recordingRepository
        )
        let clashingKey = DedupKey.icalUid("uid-atomic-clash", startEpochSeconds: 100)
        let thirdEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-atomic-third")
        try await meetingRepository.save(
            MeetingRecord(event: thirdEvent, dedupKey: clashingKey, status: .scheduled, sources: [])
        )

        do {
            try await meetingRepository.save(
                MeetingRecord(event: winnerEvent, dedupKey: clashingKey, status: .scheduled, sources: []),
                absorbing: [loserEvent.id]
            )
            XCTFail("ожидался constraintViolation на шаге (3)")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }

        let loserStillThere = try await meetingRepository.meeting(id: loserEvent.id)
        XCTAssertNotNil(loserStillThere, "откат — проигравший на месте")
        let stillBoundToLoser = try await recordingRepository.recordings(meetingId: loserEvent.id)
        XCTAssertTrue(
            stillBoundToLoser.contains { $0.manifest.recordingId == recordingId }, "перенос откачен"
        )
        let winnerRead = try await meetingRepository.meeting(id: winnerEvent.id)
        XCTAssertNil(winnerRead?.dedupKey, "победитель не переписан новым dedup_key")
    }

    /// СТРОКА (открытый вопрос v22, `GRDBMeetingRepositoryWrite.swift`): победитель — ещё
    /// не сохранённая встреча, у проигравшего есть привязанная запись — внешний ключ
    /// `recordings.meeting_id` немедленно откатывает шаг (1).
    func testAbsorbing_winnerNotYetExistingWithAttachedRecordingThrowsConstraintViolation() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let meetingRepository = temp.database.meetingRepository()
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)

        let loserEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-newwinner-loser")
        try await meetingRepository.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        _ = try await Self.seedRecording(meetingId: loserEvent.id, layout: layout, repository: recordingRepository)

        let newWinnerEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-newwinner-winner")
        do {
            try await meetingRepository.save(
                MeetingRecord(event: newWinnerEvent, dedupKey: nil, status: .scheduled, sources: []),
                absorbing: [loserEvent.id]
            )
            XCTFail("ожидался constraintViolation — внешний ключ recordings.meeting_id")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }

        let loserRead = try await meetingRepository.meeting(id: loserEvent.id)
        XCTAssertNotNil(loserRead, "откат — проигравший на месте")
    }

    /// «id, не встречающийся ни у одной строки recordings/meeting_outputs — не ошибка».
    func testAbsorbing_absentMeetingIdIsNotAnError() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetingRepository = temp.database.meetingRepository()

        let winnerEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-absent")
        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )

        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .armed, sources: []),
            absorbing: [UUID()]
        )

        let read = try await meetingRepository.meeting(id: winnerEvent.id)
        XCTAssertEqual(read?.status, .armed, "не ошибка — обычный save прошёл")
    }

    private static func seedRecording(
        meetingId: UUID, layout: FileLayout, repository: RecordingRepository
    ) async throws -> UUID {
        let recordingId = UUID()
        let directory = layout.recordingDirectory(recordingId.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        let manifest = try TestFixtures.recordingManifest(recordingId: recordingId, meetingId: meetingId)
        try await repository.save(RecordingRecord(manifest: manifest, status: .recording))
        return recordingId
    }
}
