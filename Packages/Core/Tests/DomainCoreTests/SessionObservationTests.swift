//  SessionObservationTests — MEE-456: фасад публикует `.statusChanged` на смене состояния
//  сессии из `SessionCoordinator.changes()` (C-016 v10, §«Поведение»).
//
//  Координатор — СВОЙ (`ObservedTestSessionCoordinator`), не фейк C-018 из DomainTestKit:
//  сторож К88 (`SessionCoordinatorFakeTraceTests.swift`) — тот же приём, что
//  `RecordingCommandsTests.swift`/`CaptureCompositionTests.swift`.
//
//  «РОВНО ОДНО» — СЧЁТОМ ДО БАРЬЕРА. После смены состояния тест шлёт снимки, которые сменой
//  не являются (та же `state`, другая `estimate`; спрос), и затем барьер — вторую настоящую
//  смену. Смены одного потока фасад обрабатывает по порядку, поэтому всякая лишняя публикация
//  на промежуточных снимках уходит раньше ответа на барьер. Тест собирает до трёх событий
//  после первого (предел ожидания — 1 с) и требует ровно одно: сравнение содержимого здесь
//  не годится — `status()` читает живой список сессий, и лишнее событие, обработанное после
//  `setSessions` барьера, выглядело бы как ответ на барьер.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

/// Только `.statusChanged`: `meetingsChanged` на той же смене (инв. 34 (б), MEE-482) проверяют
/// `AdHocRecordingsEventsTests`, а здесь предмет — «ровно одно `statusChanged`» (MEE-456).
private func collectStatusChanges(
    _ stream: AsyncStream<AppEvent>, count: Int, timeoutSeconds: UInt64 = 5
) async -> [AppEvent] {
    let iterator = stream.makeAsyncIterator()
    var collected: [AppEvent] = []
    while collected.count < count {
        guard let event = await nextEventOrNil(iterator, seconds: timeoutSeconds) else { break }
        if case .meetingsChanged = event { continue }
        collected.append(event)
    }
    return collected
}

final class SessionObservationTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeFacade(coordinator: ObservedTestSessionCoordinator) -> AppFacadeImpl {
        let repositories = InMemoryRepositories()
        return AppFacadeImpl(
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
            jobQueue: FakeJobQueue(),
            fileLayout: FileLayout(root: FileManager.default.temporaryDirectory),
            clock: { [epoch] in epoch }
        )
    }

    private func snapshot(
        _ sessionId: UUID, state: MeetingStatus, recordingId: UUID?, estimate: Double = 1
    ) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: sessionId, origin: .adHoc, meetingId: nil, state: state, recordingId: recordingId,
            target: nil, estimate: estimate, enteredStateAt: epoch, updatedAt: epoch
        )
    }

    /// Смена состояния в координаторе даёт ровно одно `.statusChanged`, и в нём — новое
    /// состояние; снимок без смены состояния и спрос не публикуют ничего.
    func test_sessionStateChangePublishesExactlyOneStatusChangedWithNewState() async throws {
        let coordinator = ObservedTestSessionCoordinator()
        let facade = makeFacade(coordinator: coordinator)
        let events = facade.events()
        let sessionId = UUID()
        let recordingId = UUID()

        let recording = snapshot(sessionId, state: .recording, recordingId: recordingId)
        coordinator.setSessions([recording])
        coordinator.send(.session(recording))
        // Не смены состояния: та же `state`, новая `estimate`; спрос.
        coordinator.send(.session(snapshot(sessionId, state: .recording, recordingId: recordingId, estimate: 0.5)))
        let prompt = SessionPrompt(
            promptId: UUID(), sessionId: sessionId, kind: .recordThisMeeting, raisedAt: epoch, expiresAt: nil
        )
        coordinator.send(.promptRaised(prompt))
        coordinator.send(.promptWithdrawn(promptId: prompt.promptId))

        let collectedFirst = await collectStatusChanges(events, count: 1)
        // Барьер — настоящая смена; ставится после того, как первое событие собрано, чтобы
        // `status()` первого ответа прочёл состояние ДО `setSessions` барьера.
        let stopping = snapshot(sessionId, state: .stopping, recordingId: recordingId)
        coordinator.setSessions([stopping])
        coordinator.send(.session(stopping))
        let collectedAfter = await collectStatusChanges(events, count: 3, timeoutSeconds: 1)

        guard case .statusChanged(let first)? = collectedFirst.first else {
            return XCTFail("ожидалось .statusChanged, пришло \(collectedFirst)")
        }
        let active = try XCTUnwrap(first.activeSession)
        XCTAssertEqual(active.recordingId, recordingId)
        XCTAssertEqual(active.state, .recording)

        XCTAssertEqual(collectedAfter.count, 1, "между сменой и барьером лишних публикаций быть не должно")
        guard case .statusChanged(let second)? = collectedAfter.last else {
            return XCTFail("последним обязан прийти ответ на барьер, пришло \(collectedAfter)")
        }
        XCTAssertNil(second.activeSession, "после .stopping идущей записи нет (признак инв. 9/27)")
    }

    /// Терминальная смена тоже публикуется: запись закончилась — UI узнаёт об этом событием.
    func test_terminalSessionStatePublishesStatusChanged() async {
        let coordinator = ObservedTestSessionCoordinator()
        let facade = makeFacade(coordinator: coordinator)
        let events = facade.events()
        let sessionId = UUID()

        coordinator.send(.session(snapshot(sessionId, state: .processing, recordingId: UUID())))
        _ = await collectStatusChanges(events, count: 1)
        coordinator.send(.session(snapshot(sessionId, state: .ready, recordingId: UUID())))
        let collected = await collectStatusChanges(events, count: 1)

        guard case .statusChanged? = collected.first else {
            return XCTFail("ожидалось .statusChanged на входе в .ready, пришло \(collected)")
        }
    }
}

/// Свой координатор (см. шапку файла): отдаёт заданный список сессий и один поток смен,
/// в который тест шлёт значения сам.
final class ObservedTestSessionCoordinator: SessionCoordinator, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [SessionSnapshot] = []
    private let stream: AsyncStream<SessionChange>
    private let continuation: AsyncStream<SessionChange>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: SessionChange.self)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func setSessions(_ list: [SessionSnapshot]) {
        locked { snapshots = list }
    }

    func send(_ change: SessionChange) {
        continuation.yield(change)
    }

    func sessions() async -> [SessionSnapshot] { locked { snapshots } }
    func session(id: UUID) async -> SessionSnapshot? { await sessions().first { $0.sessionId == id } }
    func prompts() async -> [SessionPrompt] { [] }
    func changes() -> AsyncStream<SessionChange> { stream }
    /// MEE-494: `recordingId`, который вернёт `startRecording`; `nil` — новый на каждый вызов.
    private var fixedRecordingId: UUID?

    func setStartRecordingId(_ recordingId: UUID?) {
        locked { fixedRecordingId = recordingId }
    }

    func startRecording(meetingId: UUID?, now: Date) async throws -> UUID { locked { fixedRecordingId } ?? UUID() }
    func stopRecording(recordingId: UUID, now: Date) async throws {}
    func skip(meetingId: UUID, now: Date) async throws {}
    func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws {}
    func start(now: Date) async {}
    func tick(now: Date) async {}
    func stop() async {}
}
