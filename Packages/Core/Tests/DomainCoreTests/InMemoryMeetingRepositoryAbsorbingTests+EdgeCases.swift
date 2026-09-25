//  InMemoryMeetingRepositoryAbsorbingTests+EdgeCases — вторая половина `save(_:absorbing:)`
//  фейка, C-010 v22 инвариант 33 (IR-133, MEE-405, MEE-407): уникальность пары источника
//  после удаления, атомарность (перенос recordings И meeting_outputs через настоящую
//  коллизию dedup_key, не искусственный `fail(with:on:)` — возврат РП, приёмка #134,
//  прежняя версия была вакуумной), и v22 — победитель обязан существовать при непустом
//  meetingIds, безусловно. Деление по объёму, не по смыслу — см. шапку
//  `InMemoryMeetingRepositoryAbsorbingTests.swift`.

import XCTest
import DomainCore
import DomainTestKit

extension InMemoryMeetingRepositoryAbsorbingTests {

    /// Мотивация метода, вторая половина (первая — `test_
    /// winnerInheritsLoserDedupKeyWithoutFalseSelfCollision`): то же самое для пары
    /// (`source_connector_id`, `external_id`).
    func test_winnerInheritsLoserSourcePairWithoutFalseSelfCollision() async throws {
        let repositories = InMemoryRepositories()
        let winnerEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = MeetingEventFixtures.withoutConference
        try await repositories.meetings.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )

        let winnerOwnSource = MeetingSource(
            sourceConnectorId: winnerEvent.sourceConnectorId, externalId: winnerEvent.externalId,
            icalUid: nil, lastModified: Date(timeIntervalSince1970: 0)
        )
        let inheritedSource = MeetingSource(
            sourceConnectorId: loserEvent.sourceConnectorId, externalId: loserEvent.externalId,
            icalUid: nil, lastModified: Date(timeIntervalSince1970: 0)
        )
        try await repositories.meetings.save(
            MeetingRecord(
                event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [winnerOwnSource, inheritedSource]
            ),
            absorbing: [loserEvent.id]
        )

        let winnerFound = try await repositories.meetings.meeting(
            sourceConnectorId: loserEvent.sourceConnectorId, externalId: loserEvent.externalId
        )
        XCTAssertEqual(winnerFound?.event.id, winnerEvent.id, "пара проигравшего теперь у победителя")
    }

    /// Пара, занятая ТРЕТЬЕЙ встречей (не проигравшим), — `constraintViolation`.
    func test_sourcePairAlreadyOwnedByThirdMeetingThrowsConstraintViolation() async throws {
        let repositories = InMemoryRepositories()
        let winnerEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: winnerEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let loserEvent = MeetingEventFixtures.withoutConference
        try await repositories.meetings.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let thirdEvent = MeetingEventFixtures.cancelled
        let clashingSource = MeetingSource(
            sourceConnectorId: thirdEvent.sourceConnectorId, externalId: thirdEvent.externalId,
            icalUid: nil, lastModified: Date(timeIntervalSince1970: 0)
        )
        try await repositories.meetings.save(
            MeetingRecord(event: thirdEvent, dedupKey: nil, status: .scheduled, sources: [clashingSource])
        )

        let winnerOwnSource = MeetingSource(
            sourceConnectorId: winnerEvent.sourceConnectorId, externalId: winnerEvent.externalId,
            icalUid: nil, lastModified: Date(timeIntervalSince1970: 0)
        )
        do {
            try await repositories.meetings.save(
                MeetingRecord(
                    event: winnerEvent, dedupKey: nil, status: .scheduled,
                    sources: [winnerOwnSource, clashingSource]
                ),
                absorbing: [loserEvent.id]
            )
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }
        let loserStillThere = try await repositories.meetings.meeting(id: loserEvent.id)
        XCTAssertNotNil(loserStillThere, "откат — проигравший на месте")
    }

    /// Атомарность: настоящая коллизия `dedup_key` с ТРЕТЬЕЙ встречей на шаге (3) — тот же
    /// вектор, что в GRDB-тесте, не искусственный `fail(with:on:)` (возврат РП, приёмка
    /// #134: прежняя версия срабатывала до какой-либо логики и не проверяла её). После
    /// отказа и запись, и выдача остаются у проигравшего.
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
        let recordingManifest = try InMemoryMeetingRepositoryAbsorbingTests.manifest(
            recordingId: recordingId, meetingId: loserEvent.id
        )
        repositories.recordings.seed([RecordingRecord(manifest: recordingManifest, status: .recording)])
        let output = MeetingOutput(
            id: UUID(), meetingId: loserEvent.id, kind: .summary, engine: "e", modelVersion: "m1",
            promptVersion: "p1", contentMarkdown: "text", structuredJson: nil,
            createdAt: Date(timeIntervalSince1970: 0), isUserEdited: false
        )
        repositories.meetingOutputs.seed([output])

        let clashingKey = DedupKey.icalUid("uid-atomic-clash-fake", startEpochSeconds: 100)
        let thirdEvent = MeetingEventFixtures.cancelled
        try await repositories.meetings.save(
            MeetingRecord(event: thirdEvent, dedupKey: clashingKey, status: .scheduled, sources: [])
        )

        do {
            try await repositories.meetings.save(
                MeetingRecord(event: winnerEvent, dedupKey: clashingKey, status: .scheduled, sources: []),
                absorbing: [loserEvent.id]
            )
            XCTFail("ожидался constraintViolation на шаге (3)")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }

        let loserStillThere = try await repositories.meetings.meeting(id: loserEvent.id)
        XCTAssertNotNil(loserStillThere, "откат — проигравший на месте")
        let stillBoundToLoser = try await repositories.recordings.recordings(meetingId: loserEvent.id)
        XCTAssertTrue(
            stillBoundToLoser.contains { $0.manifest.recordingId == recordingId }, "перенос записи откачен"
        )
        let outputsStillAtLoser = try await repositories.meetingOutputs.outputs(meetingId: loserEvent.id)
        XCTAssertEqual(outputsStillAtLoser.map(\.id), [output.id], "перенос выдачи откачен")
        let winnerRead = try await repositories.meetings.meeting(id: winnerEvent.id)
        XCTAssertNil(winnerRead?.dedupKey, "победитель не переписан новым dedup_key")
    }

    /// v22 (возврат РП, приёмка #134): победитель — ещё не сохранённая встреча, у
    /// проигравшего есть привязанная запись — фейк не слабее GRDB, воспроизводит тот же
    /// `constraintViolation` (та же явная проверка сработала бы и без дочерних строк —
    /// см. следующий тест).
    func test_winnerNotYetExistingWithAttachedRecordingThrowsConstraintViolation() async throws {
        let repositories = InMemoryRepositories()
        let loserEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )
        let recordingId = UUID()
        let recordingManifest = try InMemoryMeetingRepositoryAbsorbingTests.manifest(
            recordingId: recordingId, meetingId: loserEvent.id
        )
        repositories.recordings.seed([RecordingRecord(manifest: recordingManifest, status: .recording)])

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

    /// v22 (возврат РП, приёмка #134): тот же отказ БЕЗ единой привязанной дочерней строки —
    /// до правки срабатывал только когда были такие привязки (`isBound(toAnyOf:)`, с тех
    /// пор удалён вместе с проверкой). Победитель обязан существовать безусловно.
    func test_winnerNotYetExistingWithNoAttachedRowsThrowsConstraintViolation() async throws {
        let repositories = InMemoryRepositories()
        let loserEvent = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(
            MeetingRecord(event: loserEvent, dedupKey: nil, status: .scheduled, sources: [])
        )

        let newWinnerEvent = MeetingEventFixtures.withoutConference
        do {
            try await repositories.meetings.save(
                MeetingRecord(event: newWinnerEvent, dedupKey: nil, status: .scheduled, sources: []),
                absorbing: [loserEvent.id]
            )
            XCTFail("ожидался constraintViolation — победитель ещё не существует")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }
        let loserRead = try await repositories.meetings.meeting(id: loserEvent.id)
        XCTAssertNotNil(loserRead, "откат — проигравший на месте")
        let newWinnerRead = try await repositories.meetings.meeting(id: newWinnerEvent.id)
        XCTAssertNil(newWinnerRead, "победитель не создан")
    }
}
