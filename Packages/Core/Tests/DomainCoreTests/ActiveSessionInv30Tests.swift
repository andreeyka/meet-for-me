//  ActiveSessionInv30Tests — C-016 v11, инв. 30 (а–г), IR-142 (MEE-455), задача MEE-462:
//  поля `ActiveSessionView`, которых инв. 27 не называет.
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

    // MARK: - (а) какая сессия

    /// Окно отката: видно две сессии в `recording` — берётся та, чей `recordingId` равен
    /// `recordingId` последнего `.started`, даже если она не первая в порядке `sessions()`.
    func test_inv30a_rollbackWindowPicksSessionOfLastObservedStarted() async throws {
        let fixture = FacadeV11Fixture(clock: epoch)
        let stale = UUID()
        let live = UUID()
        fixture.coordinator.setSessions([
            recordingSession(recordingId: stale, enteredAt: epoch),
            recordingSession(recordingId: live, enteredAt: epoch)
        ])
        fixture.capture.emit(started(live, at: epoch.addingTimeInterval(3), groupKey: nil))

        let status = try await fixture.statusWhen { $0.activeSession?.recordingId == live }

        XCTAssertEqual(status.activeSession?.recordingId, live)
    }

    /// Такой нет (`.started` не наблюдён либо относится к третьей записи) — первая в порядке `sessions()`.
    func test_inv30a_withoutMatchingStartedFirstInSessionsOrderIsTaken() async {
        let fixture = FacadeV11Fixture(clock: epoch)
        let first = UUID()
        fixture.coordinator.setSessions([
            recordingSession(recordingId: first, enteredAt: epoch),
            recordingSession(recordingId: UUID(), enteredAt: epoch)
        ])

        let status = await fixture.facade.status()

        XCTAssertEqual(status.activeSession?.recordingId, first)
    }

    /// `stopping` идущей записью не считается (тот же признак, что у инв. 9).
    func test_inv30a_stoppingSessionIsNotActive() async {
        let fixture = FacadeV11Fixture(clock: epoch)
        fixture.coordinator.setSessions([SessionSnapshot(
            sessionId: UUID(), origin: .adHoc, meetingId: nil, state: .stopping, recordingId: UUID(),
            target: nil, estimate: 1, enteredStateAt: epoch, updatedAt: epoch
        )])

        let status = await fixture.facade.status()

        XCTAssertNil(status.activeSession)
    }

    // MARK: - (б) startedAt

    func test_inv30b_startedAtIsEnteredStateAtUntilStartedThenCaptureStartedAt() async throws {
        let fixture = FacadeV11Fixture(clock: epoch)
        let recordingId = UUID()
        let entered = epoch.addingTimeInterval(10)
        let captureZero = epoch.addingTimeInterval(11.5)
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId, enteredAt: entered)])

        let before = await fixture.facade.status()
        XCTAssertEqual(before.activeSession?.startedAt, entered, "до .started — enteredStateAt")

        fixture.capture.emit(started(recordingId, at: captureZero, groupKey: nil))
        let after = try await fixture.statusWhen { $0.activeSession?.startedAt != entered }
        XCTAssertEqual(after.activeSession?.startedAt, captureZero, "после .started — CaptureStarted.startedAt")
    }

    /// `.started` чужой записи `startedAt` этой сессии не задаёт.
    func test_inv30b_startedOfOtherRecordingDoesNotApply() async throws {
        let fixture = FacadeV11Fixture(clock: epoch)
        let recordingId = UUID()
        let other = UUID()
        let entered = epoch.addingTimeInterval(10)
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId, enteredAt: entered)])
        // Барьер: `.failed` публикует `failure`, события потока обрабатываются по порядку.
        let stream = fixture.facade.events()
        fixture.capture.emit(started(other, at: epoch.addingTimeInterval(99), groupKey: "zoom"))
        fixture.capture.emit(.failed(.systemUnavailable(message: "барьер")))
        _ = await collectEvents(stream, count: 1)

        let status = await fixture.facade.status()

        XCTAssertEqual(status.activeSession?.startedAt, entered)
        XCTAssertNil(status.activeSession?.requestedAppKey)
    }

    // MARK: - (в) title

    func test_inv30c_titleForMissingMeetingRowAndForReadFailureIsAdHocTitle() async {
        let fixture = FacadeV11Fixture(clock: epoch)
        fixture.coordinator.setSessions([
            recordingSession(recordingId: UUID(), meetingId: UUID(), enteredAt: epoch)
        ])

        let missing = await fixture.facade.status()
        XCTAssertEqual(missing.activeSession?.title, "Созвон без события", "строки встречи нет")

        fixture.repositories.meetings.fail(with: .io(message: "диск"), on: .meetingById)
        let failed = await fixture.facade.status()
        XCTAssertEqual(failed.activeSession?.title, "Созвон без события", "отказ чтения не бросается")
    }

    // MARK: - (г) requestedAppKey

    func test_inv30d_requestedAppKeyNilBeforeStartedThenGroupKeyThenSnapshotField() async throws {
        let fixture = FacadeV11Fixture(clock: epoch)
        let recordingId = UUID()
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId, enteredAt: epoch)])

        let beforeStarted = await fixture.facade.status()
        XCTAssertNil(beforeStarted.activeSession?.requestedAppKey, "до .started — nil")

        fixture.capture.emit(started(recordingId, at: epoch, groupKey: "us.zoom.xos"))
        let beforeSnapshot = try await fixture.statusWhen { $0.activeSession?.requestedAppKey != nil }
        XCTAssertEqual(beforeSnapshot.activeSession?.requestedAppKey, "us.zoom.xos",
                       "до первого снимка — CaptureStarted.captureGroupKey")

        // Снимок с законным `nil` («просили не по приложению») заменяет ключ группы.
        let stream = fixture.facade.events()
        fixture.capture.emit(.capturedProcessesChanged(snapshot(requestedAppKey: nil)))
        guard case .statusChanged(let afterSnapshot)? = await collectEvents(stream, count: 1).first else {
            return XCTFail("ожидалось .statusChanged на снимке")
        }
        XCTAssertNil(afterSnapshot.activeSession?.requestedAppKey, "после снимка — поле снимка, и nil тоже")
    }
}
