//  ActiveSessionInv30Tests — C-016 v11, инв. 30 (а–г), IR-142 (MEE-455), задача MEE-462:
//  поля `ActiveSessionView`, которых инв. 27 не называет. Критерии К56–К59 дельты `АВ`
//  перечня MEE-401 (`f89d2865`), по вектору на пункт критерия.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class ActiveSessionInv30Tests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func started(_ recordingId: UUID, at: Date, groupKey: String?) -> CaptureEvent {
        .started(CaptureStarted(recordingId: recordingId, startedAt: at, tracks: [], captureGroupKey: groupKey))
    }

    private func snapshot(requestedAppKey: String?) -> CapturedProcessSnapshot {
        CapturedProcessSnapshot(
            atMs: 1_000, observedAt: epoch, requestedAppKey: requestedAppKey,
            resolvedBundleIds: [], processes: [], containsUnrequested: false
        )
    }

    /// Барьер для событий захвата без публикации (`.started`): `.failed` публикует `failure`,
    /// а события одного потока фасад обрабатывает по порядку.
    private func emitWithBarrier(_ fixture: FacadeV11Fixture, _ events: [CaptureEvent]) async {
        let stream = fixture.facade.events()
        for event in events { fixture.capture.emit(event) }
        fixture.capture.emit(.failed(.systemUnavailable(message: "барьер")))
        _ = await collectEvents(stream, count: 1)
    }

    // MARK: - К56 (инв. 30а): какая сессия

    func test_k56_activeSessionChoiceAcrossFourVectors() async throws {
        // (i) Одна сессия в `recording`.
        let single = FacadeV11Fixture(clock: epoch)
        let only = UUID()
        single.coordinator.setSessions([recordingSession(recordingId: only, enteredAt: epoch)])
        let singleStatus = await single.facade.status()
        XCTAssertEqual(singleStatus.activeSession?.recordingId, only, "(i)")

        // (ii) Одна сессия в `stopping` — идущей записи нет.
        let stopping = FacadeV11Fixture(clock: epoch)
        stopping.coordinator.setSessions([SessionSnapshot(
            sessionId: UUID(), origin: .adHoc, meetingId: nil, state: .stopping, recordingId: UUID(),
            target: nil, estimate: 1, enteredStateAt: epoch, updatedAt: epoch
        )])
        let stoppingStatus = await stopping.facade.status()
        XCTAssertNil(stoppingStatus.activeSession, "(ii)")

        // (iii) S1, S2 в этом порядке; последним наблюдён `.started` записи S2.
        let window = FacadeV11Fixture(clock: epoch)
        let first = UUID()
        let second = UUID()
        window.coordinator.setSessions([
            recordingSession(recordingId: first, enteredAt: epoch),
            recordingSession(recordingId: second, enteredAt: epoch)
        ])
        let beforeStarted = await window.facade.status()
        XCTAssertEqual(beforeStarted.activeSession?.recordingId, first, "(iv) .started не наблюдался — первая")
        await emitWithBarrier(window, [started(second, at: epoch, groupKey: nil)])
        let afterStarted = await window.facade.status()
        XCTAssertEqual(afterStarted.activeSession?.recordingId, second, "(iii)")

        // (iv) `.started` с `recordingId`, которого нет ни у одной, — первая.
        await emitWithBarrier(window, [started(UUID(), at: epoch, groupKey: nil)])
        let foreignStarted = await window.facade.status()
        XCTAssertEqual(foreignStarted.activeSession?.recordingId, first, "(iv) чужой .started — первая")
    }

    // MARK: - К57 (инв. 30б): startedAt

    func test_k57_startedAtEnteredStateAtUntilOwnStartedThenCaptureStartedAt() async throws {
        let fixture = FacadeV11Fixture(clock: epoch)
        let recordingId = UUID()
        let enteredT0 = epoch.addingTimeInterval(10)
        let otherT2 = epoch.addingTimeInterval(99)
        let captureT1 = epoch.addingTimeInterval(11.5)
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId, enteredAt: enteredT0)])

        let noStarted = await fixture.facade.status()
        XCTAssertEqual(noStarted.activeSession?.startedAt, enteredT0, "(i)")

        await emitWithBarrier(fixture, [started(UUID(), at: otherT2, groupKey: nil)])
        let otherStarted = await fixture.facade.status()
        XCTAssertEqual(otherStarted.activeSession?.startedAt, enteredT0, "(ii) чужой .started не применяется")

        await emitWithBarrier(fixture, [started(recordingId, at: captureT1, groupKey: nil)])
        let ownStarted = await fixture.facade.status()
        XCTAssertEqual(ownStarted.activeSession?.startedAt, captureT1, "(iii)")
    }

    // MARK: - К58 (инв. 30в): title

    func test_k58_titleFromMeetingElseAdHocTitleIncludingMissingRowAndReadFailure() async throws {
        let fixture = FacadeV11Fixture(clock: epoch)
        let event = MeetingEventFixtures.oneOnOneZoom
        XCTAssertNotEqual(event.title, "Созвон без события", "иначе вектор (i) вакуумен")
        let record = MeetingRecord(event: event, dedupKey: nil, status: .recording, sources: [])
        fixture.repositories.meetings.seed([record])

        fixture.coordinator.setSessions([recordingSession(recordingId: UUID(), meetingId: event.id, enteredAt: epoch)])
        let named = await fixture.facade.status()
        XCTAssertEqual(named.activeSession?.title, event.title, "(i) MeetingEvent.title")

        fixture.coordinator.setSessions([recordingSession(recordingId: UUID(), enteredAt: epoch)])
        let adHoc = await fixture.facade.status()
        XCTAssertEqual(adHoc.activeSession?.title, "Созвон без события", "(ii) meetingId == nil")

        fixture.coordinator.setSessions([recordingSession(recordingId: UUID(), meetingId: UUID(), enteredAt: epoch)])
        let missing = await fixture.facade.status()
        XCTAssertEqual(missing.activeSession?.title, "Созвон без события", "(iii) строки встречи нет")

        fixture.coordinator.setSessions([recordingSession(recordingId: UUID(), meetingId: event.id, enteredAt: epoch)])
        fixture.repositories.meetings.fail(with: .io(message: "диск"), on: .meetingById)
        let failed = await fixture.facade.status()
        XCTAssertEqual(failed.activeSession?.title, "Созвон без события", "(iv) отказ чтения не бросается")
    }

    // MARK: - К59 (инв. 30г): requestedAppKey

    func test_k59_requestedAppKeyNilThenCaptureGroupKeyThenSnapshotField() async throws {
        let fixture = FacadeV11Fixture(clock: epoch)
        let recordingId = UUID()
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId, enteredAt: epoch)])

        let beforeStarted = await fixture.facade.status()
        XCTAssertNil(beforeStarted.activeSession?.requestedAppKey, "(i) до .started — nil")

        await emitWithBarrier(fixture, [started(recordingId, at: epoch, groupKey: "com.example.app")])
        let beforeSnapshot = await fixture.facade.status()
        XCTAssertEqual(beforeSnapshot.activeSession?.requestedAppKey, "com.example.app", "(ii) captureGroupKey")

        let stream = fixture.facade.events()
        fixture.capture.emit(.capturedProcessesChanged(snapshot(requestedAppKey: "com.other")))
        guard case .statusChanged(let afterSnapshot)? = await collectEvents(stream, count: 1).first else {
            return XCTFail("ожидалось .statusChanged на снимке")
        }
        XCTAssertEqual(afterSnapshot.activeSession?.requestedAppKey, "com.other", "(iii) поле снимка, инв. 27")

        // Законный `nil` снимка («просили не по приложению») тоже заменяет ключ группы.
        fixture.capture.emit(.capturedProcessesChanged(snapshot(requestedAppKey: nil)))
        guard case .statusChanged(let nilSnapshot)? = await collectEvents(stream, count: 1).first else {
            return XCTFail("ожидалось .statusChanged на втором снимке")
        }
        XCTAssertNil(nilSnapshot.activeSession?.requestedAppKey)
    }
}
