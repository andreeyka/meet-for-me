//  Общая оснастка тестов инв. 30 и 31 (C-016 v11, MEE-462): фасад на прямых фейках портов
//  с потоками захвата и очереди. Координатор — свой (сторож К88,
//  `SessionCoordinatorFakeTraceTests.swift`), тем же приёмом, что `CaptureCompositionTests`.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

struct FacadeV11Fixture {
    let facade: AppFacadeImpl
    let repositories: InMemoryRepositories
    let coordinator: V11TestSessionCoordinator
    let capture: FakeAudioCapturePort
    let jobQueue: FakeJobQueue
    let calendar: FakeCalendarPort

    init(clock: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        let repositories = InMemoryRepositories()
        let coordinator = V11TestSessionCoordinator()
        let capture = FakeAudioCapturePort()
        let jobQueue = FakeJobQueue()
        let calendar = FakeCalendarPort()
        self.repositories = repositories
        self.coordinator = coordinator
        self.capture = capture
        self.jobQueue = jobQueue
        self.calendar = calendar
        self.facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: clock),
            modelCatalog: FakeModelCatalogPort(),
            calendar: calendar,
            sessionCoordinator: coordinator,
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            capture: capture,
            jobQueue: jobQueue,
            fileLayout: FileLayout(root: FileManager.default.temporaryDirectory),
            clock: { clock }
        )
    }
}

func recordingSession(
    recordingId: UUID, meetingId: UUID? = nil, enteredAt: Date, sessionId: UUID = UUID()
) -> SessionSnapshot {
    SessionSnapshot(
        sessionId: sessionId, origin: meetingId == nil ? .adHoc : .scheduled, meetingId: meetingId,
        state: .recording, recordingId: recordingId, target: nil, estimate: 1,
        enteredStateAt: enteredAt, updatedAt: enteredAt
    )
}

/// Свой координатор (сторож К88): отдаёт заданный список сессий, команд не исполняет.
final class V11TestSessionCoordinator: SessionCoordinator, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [SessionSnapshot] = []
    private var startError: SessionError?

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func setSessions(_ list: [SessionSnapshot]) {
        locked { snapshots = list }
    }

    /// К29: отказ `startRecording`, каким машина сессии отдаёт отказ `AudioCapturePort.start()`.
    func failStartRecording(with error: SessionError) {
        locked { startError = error }
    }

    func sessions() async -> [SessionSnapshot] { locked { snapshots } }
    func session(id: UUID) async -> SessionSnapshot? { await sessions().first { $0.sessionId == id } }
    func prompts() async -> [SessionPrompt] { [] }
    func changes() -> AsyncStream<SessionChange> { AsyncStream { _ in } }
    func startRecording(meetingId: UUID?, now: Date) async throws -> UUID {
        if let error = locked({ startError }) { throw error }
        return UUID()
    }
    func stopRecording(recordingId: UUID, now: Date) async throws {}
    func skip(meetingId: UUID, now: Date) async throws {}
    func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws {}
    func start(now: Date) async {}
    func tick(now: Date) async {}
    func stop() async {}
}
