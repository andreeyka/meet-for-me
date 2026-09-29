//  RecordingCommandsTests — добор К12 по сверке покрытия MEE-401 (`484179e8`), MEE-448:
//  вектор «уже остановленная запись» — первый `stopRecording` успешен, второй с тем же
//  `recordingId` отказывает. Существующий `test_k12_stopRecordingUnknownOrAlreadyStoppedIsNoop`
//  задаёт отказ заранее обоим вызовам и потому проверяет только вектор «записи нет».
//
//  `StoppableSessionCoordinator` — СВОЯ заглушка, а не `DomainTestKit`-фейк координатора:
//  тот же запрет К88 плана MEE-288, что назван в шапке `RecordingCommandsTests.swift`. Она
//  воспроизводит ровно то поведение `SessionCoordinator.stopRecording`, которое нужно
//  вектору: запись в `.recording` останавливается (переходит в `.stopping`); запись, что
//  уже не в `.recording`, — `SessionError.noRecordingInProgress` (так же отвечает
//  `SessionMachine`, `SessionMachineCommands.swift`, «Запись уже останавливается либо
//  обрабатывается»).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

extension RecordingCommandsTests {

    // MARK: - К12 (инв. 11): первый stopRecording успешен, второй на той же записи отказывает

    func test_k12_stopRecordingAlreadyStoppedSecondCallThrowsWithoutMutations() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = UUID()
        let coordinator = StoppableSessionCoordinator(recordingId: recordingId)
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: coordinator,
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            clock: { Date() }
        )

        try await facade.stopRecording(recordingId: recordingId)
        let callsAfterFirstStop = repositories.log.calls

        do {
            try await facade.stopRecording(recordingId: recordingId)
            XCTFail("второй stopRecording уже остановленной записи обязан отказать")
        } catch AppFacadeError.notFound(let entity, let id) {
            XCTAssertEqual(entity, "Recording")
            XCTAssertEqual(id, recordingId.uuidString)
        } catch AppFacadeError.notAllowed {
            // критерий не сужает выбор между notFound/notAllowed — оба валидны
        }

        XCTAssertEqual(coordinator.stopRecordingCallCount, 2, "оба вызова дошли до SessionCoordinator")
        // Журнал общий для всех репозиториев фикстуры: отказавший второй вызов не добавляет в
        // него ни одной записи — значит, и ни одного мутирующего вызова (критерий — 0).
        XCTAssertEqual(
            repositories.log.calls, callsAfterFirstStop,
            "после первого стопа второй вызов не обращается к репозиториям вовсе"
        )
    }
}

/// Заглушка `SessionCoordinator` для вектора «уже остановленная» — см. шапку файла.
private final class StoppableSessionCoordinator: SessionCoordinator, @unchecked Sendable {
    private let lock = NSLock()
    private let recordingId: UUID
    private var state: MeetingStatus = .recording
    private var stopRecordingCalls = 0

    init(recordingId: UUID) {
        self.recordingId = recordingId
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var stopRecordingCallCount: Int { locked { stopRecordingCalls } }

    func sessions() async -> [SessionSnapshot] { [] }
    func session(id: UUID) async -> SessionSnapshot? { nil }
    func prompts() async -> [SessionPrompt] { [] }
    func changes() -> AsyncStream<SessionChange> { AsyncStream { _ in } }
    func startRecording(meetingId: UUID?, now: Date) async throws -> UUID { recordingId }

    func stopRecording(recordingId requested: UUID, now: Date) async throws {
        let stopped = locked { () -> Bool in
            stopRecordingCalls += 1
            guard requested == recordingId, state == .recording else { return false }
            state = .stopping
            return true
        }
        if !stopped {
            throw SessionError.noRecordingInProgress(recordingId: requested)
        }
    }

    func skip(meetingId: UUID, now: Date) async throws {}
    func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws {}
    func start(now: Date) async {}
    func tick(now: Date) async {}
    func stop() async {}
}
