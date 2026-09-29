//  CaptureCompositionTests — MEE-449, план MEE-410, группа Р (К42, инв. 27): состав захвата
//  проводится через `AppStatus.activeSession` без изменения, на прямых фейках портов
//  (`FakeAudioCapturePort` — ФАКП плана), не `FakeAppFacade` (план MEE-410, §0).
//
//  Половина К42 про `RecordingSummary.capturedProcesses` здесь НЕ проверяется: она достижима
//  только через `meeting(id:)`, а тот остановлен на вопросе к контракту (источник
//  `MeetingDetail.attendees`/`organizer` в C-010 не назван) — см. докстринг
//  `meeting(id:)` в `AppFacadeImpl+Reads.swift` и отчёт MEE-449.
//
//  Координатор — СВОЙ (`CaptureTestSessionCoordinator`), не фейк C-018 из DomainTestKit:
//  сторож К88 (`SessionCoordinatorFakeTraceTests.swift`) запрещает ссылаться на тот фейк из
//  этой папки — тот же приём, что `RecordingCommandsTests.swift`.
//
//  БАРЬЕР — `.statusChanged`. `handleCaptureEvent` публикует его на каждом снимке состава,
//  а события одного потока обрабатываются по порядку: дождавшись `.statusChanged` снимка,
//  тест знает, что и всё, что пришло раньше (`.started`, `.levels`), уже применено.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class CaptureCompositionTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let coordinator: CaptureTestSessionCoordinator
        let capture: FakeAudioCapturePort
    }

    private func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
        let coordinator = CaptureTestSessionCoordinator()
        let capture = FakeAudioCapturePort()
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: epoch),
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: coordinator,
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            capture: capture,
            jobQueue: FakeJobQueue(),
            fileLayout: FileLayout(root: FileManager.default.temporaryDirectory),
            clock: { [epoch] in epoch }
        )
        return Fixture(facade: facade, repositories: repositories, coordinator: coordinator, capture: capture)
    }

    private func recordingSession(recordingId: UUID, meetingId: UUID? = nil) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: UUID(), origin: meetingId == nil ? .adHoc : .scheduled, meetingId: meetingId,
            state: .recording, recordingId: recordingId, target: nil, estimate: 1,
            enteredStateAt: epoch.addingTimeInterval(5), updatedAt: epoch.addingTimeInterval(5)
        )
    }

    private func started(_ recordingId: UUID) -> CaptureEvent {
        .started(CaptureStarted(recordingId: recordingId, startedAt: epoch, tracks: [], captureGroupKey: "zoom"))
    }

    private func snapshot(requestedAppKey: String?, containsUnrequested: Bool) throws -> CapturedProcessSnapshot {
        CapturedProcessSnapshot(
            atMs: 1_500,
            observedAt: epoch.addingTimeInterval(2),
            requestedAppKey: requestedAppKey,
            resolvedBundleIds: ["us.zoom.xos", "com.apple.Safari"],
            processes: [
                try RecordingManifest.CapturedProcess(pid: 101, bundleId: "us.zoom.xos", executableName: "zoom.us"),
                try RecordingManifest.CapturedProcess(pid: 202, bundleId: "com.apple.Safari", executableName: nil)
            ],
            containsUnrequested: containsUnrequested
        )
    }

    /// Шлёт события захвата и ждёт `.statusChanged`, опубликованный последним из них (снимком).
    private func emitAndAwaitStatus(_ fixture: Fixture, _ events: [CaptureEvent]) async -> AppStatus? {
        let stream = fixture.facade.events()
        for event in events { fixture.capture.emit(event) }
        guard case .statusChanged(let status)? = await collectEvents(stream, count: 1).first else { return nil }
        return status
    }

    // MARK: - К42 (инв. 27): три поля ActiveSessionView = поля последнего снимка C-004

    func test_k42_activeSessionFieldsPassThroughUnchanged() async throws {
        let fixture = makeFixture()
        let recordingId = UUID()
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId)])
        let first = try snapshot(requestedAppKey: "zoom", containsUnrequested: false)
        let last = try snapshot(requestedAppKey: "us.zoom.xos", containsUnrequested: true)

        _ = await emitAndAwaitStatus(fixture, [started(recordingId), .capturedProcessesChanged(first)])
        let published = await emitAndAwaitStatus(fixture, [.capturedProcessesChanged(last)])
        let read = await fixture.facade.status()

        for session in [published?.activeSession, read.activeSession] {
            let session = try XCTUnwrap(session)
            XCTAssertEqual(session.recordingId, recordingId)
            XCTAssertEqual(session.capturedProcesses, last.processes, "последний снимок, без изменения")
            XCTAssertEqual(session.containsUnrequested, last.containsUnrequested)
            XCTAssertEqual(session.requestedAppKey, last.requestedAppKey)
        }
    }

    /// Отдельный вектор К42: до первого снимка — `[]`/`false` («ещё не наблюдали»).
    func test_k42_beforeFirstSnapshotCapturedProcessesEmptyAndNotUnrequested() async throws {
        let fixture = makeFixture()
        let recordingId = UUID()
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId)])
        // Ни одного события захвата: фасад ещё ничего не наблюдал.
        let status = await fixture.facade.status()
        let session = try XCTUnwrap(status.activeSession)

        XCTAssertEqual(session.recordingId, recordingId)
        XCTAssertEqual(session.capturedProcesses, [])
        XCTAssertFalse(session.containsUnrequested)
        XCTAssertNil(session.micLevel)
        XCTAssertNil(session.systemLevel)
    }

    /// Снимок прошлой записи не выдаётся за состав новой: после `.started` новой записи —
    /// снова «ещё не наблюдали», пока не придёт её собственный снимок.
    func test_k42_snapshotOfPreviousRecordingNotShownForNewRecording() async throws {
        let fixture = makeFixture()
        let previousId = UUID()
        let currentId = UUID()
        _ = await emitAndAwaitStatus(fixture, [
            started(previousId),
            .capturedProcessesChanged(try snapshot(requestedAppKey: "zoom", containsUnrequested: true))
        ])
        fixture.coordinator.setSessions([recordingSession(recordingId: currentId)])
        let fresh = try snapshot(requestedAppKey: nil, containsUnrequested: false)
        fixture.capture.emit(started(currentId))
        let statusBeforeFresh = await fixture.facade.status()
        let beforeFresh = try XCTUnwrap(statusBeforeFresh.activeSession)
        XCTAssertEqual(beforeFresh.capturedProcesses, [])
        XCTAssertFalse(beforeFresh.containsUnrequested)

        let statusAfter = await emitAndAwaitStatus(fixture, [.capturedProcessesChanged(fresh)])
        let after = try XCTUnwrap(statusAfter?.activeSession)
        XCTAssertEqual(after.recordingId, currentId)
        XCTAssertEqual(after.capturedProcesses, fresh.processes)
        XCTAssertNil(after.requestedAppKey)
    }

    // MARK: - Инв. 27: «пока идущей записи нет, activeSession равен nil»

    func test_k42_noRecordingSessionGivesNilActiveSession() async throws {
        let fixture = makeFixture()
        let armed = SessionSnapshot(
            sessionId: UUID(), origin: .scheduled, meetingId: UUID(), state: .armed, recordingId: nil,
            target: nil, estimate: 0, enteredStateAt: epoch, updatedAt: epoch
        )
        fixture.coordinator.setSessions([armed])
        _ = await emitAndAwaitStatus(fixture, [
            started(UUID()),
            .capturedProcessesChanged(try snapshot(requestedAppKey: "zoom", containsUnrequested: true))
        ])

        let status = await fixture.facade.status()
        XCTAssertNil(status.activeSession)
    }

    // MARK: - Уровни (§«Поведение»): приходят событием потока, проводятся без изменения

    func test_activeSessionLevelsPassThroughFromCaptureEvents() async throws {
        let fixture = makeFixture()
        let recordingId = UUID()
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId)])
        let status = await emitAndAwaitStatus(fixture, [
            started(recordingId),
            .levels(CaptureLevels(mic: 0.25, system: nil)),
            .capturedProcessesChanged(try snapshot(requestedAppKey: "zoom", containsUnrequested: false))
        ])

        let session = try XCTUnwrap(status?.activeSession)
        XCTAssertEqual(session.micLevel, 0.25)
        XCTAssertNil(session.systemLevel, "nil — законное значение канала, которого нет (C-004)")
    }

    // MARK: - Идентичность сессии — из SessionCoordinator; title — §1

    func test_activeSessionIdentityFromCoordinatorAndTitleFromMeeting() async throws {
        let fixture = makeFixture()
        let event = MeetingEventFixtures.oneOnOneZoom
        let record = MeetingRecord(event: event, dedupKey: nil, status: .recording, sources: [])
        fixture.repositories.meetings.seed([record])
        let scheduledRecording = UUID()
        fixture.coordinator.setSessions([recordingSession(recordingId: scheduledRecording, meetingId: event.id)])

        let scheduledStatus = await fixture.facade.status()
        let scheduled = try XCTUnwrap(scheduledStatus.activeSession)
        XCTAssertEqual(scheduled.meetingId, event.id)
        XCTAssertEqual(scheduled.title, event.title)
        XCTAssertEqual(scheduled.state, .recording)
        XCTAssertEqual(scheduled.startedAt, epoch.addingTimeInterval(5))

        fixture.coordinator.setSessions([recordingSession(recordingId: UUID())])
        let adHocStatus = await fixture.facade.status()
        let adHoc = try XCTUnwrap(adHocStatus.activeSession)
        XCTAssertNil(adHoc.meetingId)
        XCTAssertEqual(adHoc.title, "Созвон без события")
    }
}

/// Свой координатор (см. шапку файла): отвечает заданным списком сессий, команд не исполняет.
private final class CaptureTestSessionCoordinator: SessionCoordinator, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [SessionSnapshot] = []

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func setSessions(_ list: [SessionSnapshot]) {
        locked { snapshots = list }
    }

    func sessions() async -> [SessionSnapshot] {
        locked { snapshots }
    }

    func session(id: UUID) async -> SessionSnapshot? {
        await sessions().first { $0.sessionId == id }
    }

    func prompts() async -> [SessionPrompt] { [] }
    func changes() -> AsyncStream<SessionChange> { AsyncStream { _ in } }
    func startRecording(meetingId: UUID?, now: Date) async throws -> UUID { UUID() }
    func stopRecording(recordingId: UUID, now: Date) async throws {}
    func skip(meetingId: UUID, now: Date) async throws {}
    func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws {}
    func start(now: Date) async {}
    func tick(now: Date) async {}
    func stop() async {}
}
