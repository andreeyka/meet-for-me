//  InMemoryMeetingRepositoryAbsorbingTests — `save(_:absorbing:)` фейка, C-010 v21
//  инвариант 33 (IR-133, MEE-405, MEE-407) — те же векторы, что
//  `MeetingRepositoryAbsorbingTests.swift` (StorageTests, GRDB), на
//  `InMemoryMeetingRepository`: контракт требует, чтобы тест на фейке ловил те же
//  ошибки, что тест на настоящей базе (§«Фейк для тестов» C-010).

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryMeetingRepositoryAbsorbingTests: XCTestCase {

    func test_emptyMeetingIdsBehavesAsOrdinarySave() async throws {
        let repositories = InMemoryRepositories()
        let event = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: []), absorbing: []
        )
        let read = try await repositories.meetings.meeting(id: event.id)
        XCTAssertNotNil(read, "пустой meetingIds — эквивалент обычного save")
    }

    func test_meetingIdsContainingRecordEventIdThrowsConstraintViolation() async throws {
        let repositories = InMemoryRepositories()
        let event = MeetingEventFixtures.oneOnOneZoom
        do {
            try await repositories.meetings.save(
                MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: []),
                absorbing: [event.id]
            )
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }
        let read = try await repositories.meetings.meeting(id: event.id)
        XCTAssertNil(read, "ничего не создано")
    }

    /// Победитель УЖЕ существует (update-in-place) — перенос `recordings`/`meeting_outputs`
    /// не встречает симулированного внешнего ключа (`isBound(toAnyOf:)`).
    func test_transfersRecordingsAndOutputsToPreexistingWinnerAndDeletesLoser() async throws {
        let repositories = InMemoryRepositories()
        let winnerEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = MeetingEventFixtures.withoutConference
        try await repositories.meetings.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let recordingId = UUID()
        let manifest = try Self.manifest(recordingId: recordingId, meetingId: loserEvent.id)
        repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .recording)])
        let output = MeetingOutput(
            id: UUID(), meetingId: loserEvent.id, kind: .summary, engine: "e", modelVersion: "m1",
            promptVersion: "p1", contentMarkdown: "text", structuredJson: nil,
            createdAt: Date(timeIntervalSince1970: 0), isUserEdited: false
        )
        repositories.meetingOutputs.seed([output])

        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: []),
            absorbing: [loserEvent.id]
        )

        let loserRead = try await repositories.meetings.meeting(id: loserEvent.id)
        XCTAssertNil(loserRead, "проигравший удалён")
        let recordingsForWinner = try await repositories.recordings.recordings(meetingId: winnerEvent.id)
        XCTAssertTrue(
            recordingsForWinner.contains { $0.manifest.recordingId == recordingId }, "запись перенесена"
        )
        let outputsForWinner = try await repositories.meetingOutputs.outputs(meetingId: winnerEvent.id)
        XCTAssertEqual(outputsForWinner.map(\.id), [output.id], "выдача перенесена")
    }

    /// Мотивация метода: победитель наследует `dedup_key` проигравшего без ложной
    /// коллизии с самим проигравшим (проверка — уже после его удаления из рассмотрения).
    func test_winnerInheritsLoserDedupKeyWithoutFalseSelfCollision() async throws {
        let repositories = InMemoryRepositories()
        let winnerEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let sharedKey = DedupKey.icalUid("uid-inherit-fake", startEpochSeconds: 200)
        let loserEvent = MeetingEventFixtures.withoutConference
        try await repositories.meetings.save(
            MeetingRecord(event: loserEvent, dedupKey: sharedKey, status: .scheduled, sources: [])
        )

        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: sharedKey, status: .scheduled, sources: []),
            absorbing: [loserEvent.id]
        )

        let winnerRead = try await repositories.meetings.meeting(id: winnerEvent.id)
        XCTAssertEqual(winnerRead?.dedupKey, sharedKey)
    }

    /// Атомарность: искусственный отказ на шаге (3) (`fail(with:on:.save)`, тот же адрес,
    /// что проверяет `save(_:absorbing:)` до первой мутации) не переносит и не удаляет.
    func test_atomicRollbackOnStep3FailureTransfersNothingDeletesNothing() async throws {
        let repositories = InMemoryRepositories()
        let winnerEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = MeetingEventFixtures.withoutConference
        try await repositories.meetings.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let recordingId = UUID()
        let manifest = try Self.manifest(recordingId: recordingId, meetingId: loserEvent.id)
        repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .recording)])

        let failure = StorageError.constraintViolation(message: "искусственный отказ шага (3)")
        repositories.meetings.fail(with: failure, on: .save, id: winnerEvent.id.uuidString)

        do {
            try await repositories.meetings.save(
                MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: []),
                absorbing: [loserEvent.id]
            )
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }

        let loserStillThere = try await repositories.meetings.meeting(id: loserEvent.id)
        XCTAssertNotNil(loserStillThere, "откат — проигравший на месте")
        let stillBoundToLoser = try await repositories.recordings.recordings(meetingId: loserEvent.id)
        XCTAssertTrue(
            stillBoundToLoser.contains { $0.manifest.recordingId == recordingId }, "перенос откачен"
        )
    }

    /// СТРОКА (открытый вопрос v22 у GRDB, шапка `GRDBMeetingRepositoryWrite.swift`):
    /// победитель — ещё не сохранённая встреча, у проигравшего есть привязанная запись —
    /// фейк не слабее GRDB, воспроизводит тот же `constraintViolation`.
    func test_winnerNotYetExistingWithAttachedRecordingThrowsConstraintViolation() async throws {
        let repositories = InMemoryRepositories()
        let loserEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let recordingId = UUID()
        let manifest = try Self.manifest(recordingId: recordingId, meetingId: loserEvent.id)
        repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .recording)])

        let newWinnerEvent = MeetingEventFixtures.withoutConference
        do {
            try await repositories.meetings.save(
                MeetingRecord(event: newWinnerEvent, dedupKey: nil, status: .scheduled, sources: []),
                absorbing: [loserEvent.id]
            )
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }
        let loserRead = try await repositories.meetings.meeting(id: loserEvent.id)
        XCTAssertNotNil(loserRead, "откат — проигравший на месте")
    }

    /// «id, не встречающийся ни у одной строки recordings/meeting_outputs — не ошибка».
    func test_absentMeetingIdIsNotAnError() async throws {
        let repositories = InMemoryRepositories()
        let winnerEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .armed, sources: []),
            absorbing: [UUID()]
        )
        let read = try await repositories.meetings.meeting(id: winnerEvent.id)
        XCTAssertEqual(read?.status, .armed, "не ошибка — обычный save прошёл")
    }

    private static func manifest(recordingId: UUID, meetingId: UUID) throws -> RecordingManifest {
        try RecordingManifest(
            recordingId: recordingId,
            meetingId: meetingId,
            directoryName: recordingId.uuidString,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: nil,
            tracks: [
                try RecordingManifest.Track(
                    channel: .mic, fileName: "audio-mic.caf", sampleRate: 16_000, channelCount: 1, format: "pcm-caf"
                )
            ],
            markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: [], discontinuities: [], isFinalized: false
        )
    }
}
