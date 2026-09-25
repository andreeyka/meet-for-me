//  MeetingRepositoryAbsorbingTests+EdgeCases — вторая половина `save(_:absorbing:)`,
//  C-010 v22 инвариант 33 (IR-133, MEE-405, MEE-407): уникальность пары источника после
//  удаления, атомарность (перенос recordings И meeting_outputs), и v22 — победитель
//  обязан существовать при непустом meetingIds, безусловно. Деление по объёму, не по
//  смыслу — см. шапку `MeetingRepositoryAbsorbingTests.swift`.

import XCTest
import DomainCore
@testable import Storage

extension MeetingRepositoryAbsorbingTests {

    /// Мотивация метода, вторая половина (первая — `testAbsorbing_
    /// winnerInheritsLoserDedupKeyWithoutFalseSelfCollision`): то же самое для пары
    /// (`source_connector_id`, `external_id`) — победитель явно объявляет пару проигравшего
    /// среди своих `sources` (инвариант 31), и коллизия с самим проигравшим не мешает,
    /// потому что его строка `meeting_sources` уже удалена шагом (2) к моменту проверки
    /// на шаге (3).
    func testAbsorbing_winnerInheritsLoserSourcePairWithoutFalseSelfCollision() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetingRepository = temp.database.meetingRepository()

        let winnerEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-pair-winner")
        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-pair-loser")
        try await meetingRepository.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )

        let winnerOwnSource = MeetingSource(
            sourceConnectorId: winnerEvent.sourceConnectorId, externalId: winnerEvent.externalId,
            icalUid: nil, lastModified: TestFixtures.epoch
        )
        let inheritedSource = MeetingSource(
            sourceConnectorId: loserEvent.sourceConnectorId, externalId: loserEvent.externalId,
            icalUid: nil, lastModified: TestFixtures.epoch
        )
        try await meetingRepository.save(
            MeetingRecord(
                event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [winnerOwnSource, inheritedSource]
            ),
            absorbing: [loserEvent.id]
        )

        let winnerFound = try await meetingRepository.meeting(
            sourceConnectorId: loserEvent.sourceConnectorId, externalId: loserEvent.externalId
        )
        XCTAssertEqual(winnerFound?.event.id, winnerEvent.id, "пара проигравшего теперь у победителя")
    }

    /// Пара, занятая ТРЕТЬЕЙ встречей (не проигравшим), — `constraintViolation` на шаге (3),
    /// как и у `save(_:)` (К92): проверка не отменяется, а только откладывается до
    /// удаления списка `meetingIds`.
    func testAbsorbing_sourcePairAlreadyOwnedByThirdMeetingThrowsConstraintViolation() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetingRepository = temp.database.meetingRepository()

        let winnerEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-pairclash-winner")
        try await meetingRepository.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-pairclash-loser")
        try await meetingRepository.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let thirdEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-pairclash-third")
        let clashingSource = MeetingSource(
            sourceConnectorId: thirdEvent.sourceConnectorId, externalId: thirdEvent.externalId,
            icalUid: nil, lastModified: TestFixtures.epoch
        )
        try await meetingRepository.save(
            MeetingRecord(event: thirdEvent, dedupKey: nil, status: .scheduled, sources: [clashingSource])
        )

        let winnerOwnSource = MeetingSource(
            sourceConnectorId: winnerEvent.sourceConnectorId, externalId: winnerEvent.externalId,
            icalUid: nil, lastModified: TestFixtures.epoch
        )
        do {
            try await meetingRepository.save(
                MeetingRecord(
                    event: winnerEvent, dedupKey: nil, status: .scheduled,
                    sources: [winnerOwnSource, clashingSource]
                ),
                absorbing: [loserEvent.id]
            )
            XCTFail("ожидался constraintViolation на шаге (3)")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }
        let loserStillThere = try await meetingRepository.meeting(id: loserEvent.id)
        XCTAssertNotNil(loserStillThere, "откат — проигравший на месте")
    }

    /// Атомарность: отказ на шаге (3) (`dedup_key`, занятый ТРЕТЬЕЙ встречей — шаги (1)/(2)
    /// сами по себе ничего не нарушают) откатывает всю транзакцию целиком — и перенос
    /// `recordings`, и перенос `meeting_outputs`.
    func testAbsorbing_atomicRollbackOnStep3FailureTransfersNothingDeletesNothing() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let meetingRepository = temp.database.meetingRepository()
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let outputRepository = temp.database.meetingOutputRepository()

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
        let output = MeetingOutput(
            id: UUID(), meetingId: loserEvent.id, kind: .summary, engine: "e", modelVersion: "m1",
            promptVersion: "p1", contentMarkdown: "text", structuredJson: nil,
            createdAt: TestFixtures.epoch, isUserEdited: false
        )
        try await outputRepository.save(output)
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
            stillBoundToLoser.contains { $0.manifest.recordingId == recordingId }, "перенос записи откачен"
        )
        let outputsStillAtLoser = try await outputRepository.outputs(meetingId: loserEvent.id)
        XCTAssertEqual(outputsStillAtLoser.map(\.id), [output.id], "перенос выдачи откачен")
        let winnerRead = try await meetingRepository.meeting(id: winnerEvent.id)
        XCTAssertNil(winnerRead?.dedupKey, "победитель не переписан новым dedup_key")
    }

    /// v22 (возврат РП, приёмка #134): победитель — ещё не сохранённая встреча, у
    /// проигравшего есть привязанная запись — внешний ключ `recordings.meeting_id`
    /// немедленно откатывает шаг (1) (та же явная проверка сработала бы и без дочерних
    /// строк — см. следующий тест).
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
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }

        let loserRead = try await meetingRepository.meeting(id: loserEvent.id)
        XCTAssertNotNil(loserRead, "откат — проигравший на месте")
    }

    /// v22 (возврат РП, приёмка #134): тот же отказ БЕЗ единой привязанной дочерней строки —
    /// до правки срабатывал только внешний ключ, а без дочерних строк UPDATE не менял ни
    /// одной строки, и метод молча создавал бы нового победителя. Явная проверка
    /// (`SELECT 1 FROM meetings WHERE id = ?`) в `GRDBMeetingRepositoryWrite.swift` делает
    /// отказ безусловным.
    func testAbsorbing_winnerNotYetExistingWithNoAttachedRowsThrowsConstraintViolation() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetingRepository = temp.database.meetingRepository()

        let loserEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-newwinner-bare-loser")
        try await meetingRepository.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )

        let newWinnerEvent = try TestFixtures.meetingEvent(externalId: "ext-abs-newwinner-bare-winner")
        do {
            try await meetingRepository.save(
                MeetingRecord(event: newWinnerEvent, dedupKey: nil, status: .scheduled, sources: []),
                absorbing: [loserEvent.id]
            )
            XCTFail("ожидался constraintViolation — победитель ещё не существует")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }

        let loserRead = try await meetingRepository.meeting(id: loserEvent.id)
        XCTAssertNotNil(loserRead, "откат — проигравший на месте")
        let newWinnerRead = try await meetingRepository.meeting(id: newWinnerEvent.id)
        XCTAssertNil(newWinnerRead, "победитель не создан")
    }
}
