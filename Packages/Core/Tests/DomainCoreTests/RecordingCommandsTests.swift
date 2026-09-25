//  RecordingCommandsTests — MEE-420 часть 3, план MEE-410, группа В (К10-К12): команды
//  записи `AppFacadeImpl.startRecording`/`stopRecording` на прямых фейках портов, не
//  `FakeAppFacade` (план MEE-410, §0).
//
//  `TestSessionCoordinator` — СВОЙ, а не `DomainTestKit.FakeSessionCoordinator`: К88 плана
//  MEE-288 (`SessionCoordinatorFakeTraceTests.swift`) красит любой файл в `Tests/
//  DomainCoreTests/`, кодово ссылающийся на тот фейк, кроме его собственного теста, —
//  буквальный запрет на уровне всей папки, а не только тестов самой машины. Приёмка РП
//  (MEE-420, 09:50 UTC): свои заглушки координатора — допустимое решение, сторож не
//  ослаблен; уточнение области К88 («тесты машины» против «вся папка») отложено QA к
//  следующей дельте MEE-288, не задача этого файла.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class RecordingCommandsTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let sessionCoordinator: TestSessionCoordinator
    }

    private func makeFacade(permissions permissionsOverride: FakePermissionsPort? = nil) -> Fixture {
        let repositories = InMemoryRepositories()
        let permissions = permissionsOverride
            ?? FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: epoch)
        let sessionCoordinator = TestSessionCoordinator()
        let clock = ManualClock(now: epoch)
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: permissions,
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: sessionCoordinator,
            attribution: FakeAttributionPort(),
            clock: { clock.now() }
        )
        return Fixture(facade: facade, repositories: repositories, sessionCoordinator: sessionCoordinator)
    }

    private func snapshot(state: MeetingStatus, recordingId: UUID? = nil) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: UUID(), origin: .adHoc, meetingId: nil, state: state, recordingId: recordingId,
            target: nil, estimate: 0, enteredStateAt: epoch, updatedAt: epoch
        )
    }

    // MARK: - К10 (инв. 9): уже идущая запись бросает notAllowed

    func test_k10_startRecordingWhileActiveThrowsNotAllowed() async throws {
        let fixture = makeFacade()
        fixture.sessionCoordinator.setSessions([snapshot(state: .recording, recordingId: UUID())])

        do {
            _ = try await fixture.facade.startRecording(meetingId: nil)
            XCTFail("ожидался notAllowed")
        } catch AppFacadeError.notAllowed {
            // ожидаемо
        }

        XCTAssertEqual(
            fixture.sessionCoordinator.startRecordingCallCount, 0,
            "второй startRecording у SessionCoordinator не должен был вызываться сверх уже идущей сессии"
        )
    }

    // MARK: - К11 (инв. 10): без права на запись бросает permissionRequired с конкретным правом

    func test_k11_startRecordingWithoutPermissionThrowsPermissionRequired() async throws {
        let deniedPermissions = FakePermissionsPort(
            startingStatus: .denied, startingOutcome: .denied, checkedAt: epoch
        )
        let fixture = makeFacade(permissions: deniedPermissions)

        do {
            _ = try await fixture.facade.startRecording(meetingId: nil)
            XCTFail("ожидался permissionRequired")
        } catch AppFacadeError.permissionRequired(let kind) {
            XCTAssertEqual(kind, .microphone, "конкретное право, не общая ошибка")
        }

        XCTAssertEqual(
            fixture.sessionCoordinator.startRecordingCallCount, 0,
            "без права SessionCoordinator не должен вызываться вовсе"
        )
    }

    // MARK: - К12 (инв. 11): stopRecording на неизвестной/уже остановленной записи — не портит состояние

    func test_k12_stopRecordingUnknownOrAlreadyStoppedIsNoop() async throws {
        let fixture = makeFacade()
        let recordingId = UUID()
        fixture.sessionCoordinator.failStopRecording(with: .noRecordingInProgress(recordingId: recordingId))

        for attempt in 1...2 {
            do {
                try await fixture.facade.stopRecording(recordingId: recordingId)
                XCTFail("попытка \(attempt): ожидался notFound либо notAllowed")
            } catch AppFacadeError.notFound(let entity, let id) {
                XCTAssertEqual(entity, "Recording")
                XCTAssertEqual(id, recordingId.uuidString)
            } catch AppFacadeError.notAllowed {
                // критерий не сужает выбор между notFound/notAllowed — оба валидны
            }
        }

        XCTAssertTrue(
            fixture.repositories.log.calls(port: "RecordingRepository").isEmpty,
            "фасад не трогает RecordingRepository напрямую — мутация (если есть) внутри SessionCoordinator"
        )
    }

    // MARK: - Приёмка РП 09:50 UTC (инв. 23) и 10:15 UTC (recoverySuggestion) на CaptureError

    private struct CaptureErrorRow {
        let error: CaptureError
        let expectedCode: String
        let expectedPermissionKind: PermissionKind?
        /// §3.1: `recoverySuggestion` не устойчив и не предмет теста на равенство —
        /// проверяется только его наличие/отсутствие, не точный текст.
        let expectsRecoverySuggestion: Bool
    }

    private var captureErrorRows: [CaptureErrorRow] {
        [
            CaptureErrorRow(
                error: .alreadyRunning, expectedCode: "capture.alreadyRunning",
                expectedPermissionKind: nil, expectsRecoverySuggestion: false
            ),
            CaptureErrorRow(
                error: .notRunning, expectedCode: "capture.notRunning",
                expectedPermissionKind: nil, expectsRecoverySuggestion: false
            ),
            CaptureErrorRow(
                error: .nothingToCapture, expectedCode: "capture.nothingToCapture",
                expectedPermissionKind: nil, expectsRecoverySuggestion: false
            ),
            CaptureErrorRow(
                error: .systemAudioDenied, expectedCode: "capture.systemAudioDenied",
                expectedPermissionKind: .systemAudioRecording, expectsRecoverySuggestion: false
            ),
            CaptureErrorRow(
                error: .systemAudioPromptTimedOut(waitedSeconds: 45),
                expectedCode: "capture.systemAudioPromptTimedOut",
                expectedPermissionKind: nil, expectsRecoverySuggestion: true
            ),
            CaptureErrorRow(
                error: .microphoneDenied, expectedCode: "capture.microphoneDenied",
                expectedPermissionKind: .microphone, expectsRecoverySuggestion: false
            ),
            CaptureErrorRow(
                error: .microphonePromptTimedOut(waitedSeconds: 45),
                expectedCode: "capture.microphonePromptTimedOut",
                expectedPermissionKind: nil, expectsRecoverySuggestion: true
            ),
            CaptureErrorRow(
                error: .inputDeviceUnavailable(uid: "built-in"),
                expectedCode: "capture.inputDeviceUnavailable",
                expectedPermissionKind: nil, expectsRecoverySuggestion: false
            ),
            CaptureErrorRow(
                error: .directoryUnusable(message: "нет места на диске"),
                expectedCode: "capture.directoryUnusable",
                expectedPermissionKind: nil, expectsRecoverySuggestion: false
            ),
            CaptureErrorRow(
                error: .systemUnavailable(message: "Core Audio недоступен"),
                expectedCode: "capture.systemUnavailable",
                expectedPermissionKind: nil, expectsRecoverySuggestion: false
            ),
            CaptureErrorRow(
                error: .recoveryFailed(directoryName: "rec-1", message: "манифест повреждён"),
                expectedCode: "capture.recoveryFailed",
                expectedPermissionKind: nil, expectsRecoverySuggestion: false
            )
        ]
    }

    func test_wrapCaptureError_codeAndPermissionKindPerCase() async throws {
        for row in captureErrorRows {
            let fixture = makeFacade()
            fixture.sessionCoordinator.failStartRecording(with: .capture(row.error))

            do {
                _ = try await fixture.facade.startRecording(meetingId: nil)
                XCTFail("\(row.error): ожидался AppFacadeError.underlying")
            } catch AppFacadeError.underlying(let view) {
                XCTAssertEqual(view.code, row.expectedCode, "\(row.error)")
                XCTAssertEqual(view.permissionKind, row.expectedPermissionKind, "\(row.error)")
                XCTAssertEqual(
                    view.recoverySuggestion != nil, row.expectsRecoverySuggestion,
                    "\(row.error): §3.1 — recoverySuggestion обязан говорить вместо permissionKind у PromptTimedOut"
                )
            }
        }
    }

    // MARK: - Приёмка РП 09:50 UTC: представительные случаи SessionError, не покрытые К10-К12

    func test_wrapSessionError_representativeCases() async throws {
        let meetingId = UUID()
        let fixture1 = makeFacade()
        fixture1.sessionCoordinator.failStartRecording(with: .noSuchMeeting(meetingId: meetingId))
        do {
            _ = try await fixture1.facade.startRecording(meetingId: meetingId)
            XCTFail("ожидался notFound")
        } catch AppFacadeError.notFound(let entity, let id) {
            XCTAssertEqual(entity, "Meeting")
            XCTAssertEqual(id, meetingId.uuidString)
        }

        // Бэклог РП: сообщение alreadyRecording обязано нести sessionId — для диагностики.
        let busySessionId = UUID()
        let fixture2 = makeFacade()
        fixture2.sessionCoordinator.failStartRecording(with: .alreadyRecording(sessionId: busySessionId))
        do {
            _ = try await fixture2.facade.startRecording(meetingId: nil)
            XCTFail("ожидался notAllowed")
        } catch AppFacadeError.notAllowed(let reason) {
            XCTAssertTrue(
                reason.contains(busySessionId.uuidString),
                "сообщение обязано нести sessionId занятой сессии для диагностики: \(reason)"
            )
        }

        let fixture3 = makeFacade()
        fixture3.sessionCoordinator.failStartRecording(with: .nothingToRecord)
        do {
            _ = try await fixture3.facade.startRecording(meetingId: nil)
            XCTFail("ожидался notAllowed")
        } catch AppFacadeError.notAllowed {
            // ожидаемо
        }
    }
}

/// Минимальный `SessionCoordinator` собственного изготовления для этого файла — см. шапку
/// файла про К88/`SessionCoordinatorFakeTraceTests.swift`. Поддерживает ровно то, что нужно
/// К10-К12: заданные снимки сессий, отказ `stopRecording` и счётчик вызовов `startRecording`.
private final class TestSessionCoordinator: SessionCoordinator, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [SessionSnapshot] = []
    private var stopRecordingError: SessionError?
    private var startRecordingError: SessionError?
    private var startRecordingCalls = 0

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func setSessions(_ list: [SessionSnapshot]) {
        locked { snapshots = list }
    }

    func failStopRecording(with error: SessionError) {
        locked { stopRecordingError = error }
    }

    func failStartRecording(with error: SessionError) {
        locked { startRecordingError = error }
    }

    var startRecordingCallCount: Int {
        locked { startRecordingCalls }
    }

    func sessions() async -> [SessionSnapshot] {
        locked { snapshots }
    }

    func session(id: UUID) async -> SessionSnapshot? {
        locked { snapshots.first { $0.sessionId == id } }
    }

    func prompts() async -> [SessionPrompt] { [] }

    func changes() -> AsyncStream<SessionChange> {
        AsyncStream { _ in }
    }

    func startRecording(meetingId: UUID?, now: Date) async throws -> UUID {
        locked { startRecordingCalls += 1 }
        if let error = locked({ startRecordingError }) {
            throw error
        }
        return UUID()
    }

    func stopRecording(recordingId: UUID, now: Date) async throws {
        if let error = locked({ stopRecordingError }) {
            throw error
        }
    }

    func skip(meetingId: UUID, now: Date) async throws {}

    func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws {}

    func start(now: Date) async {}

    func tick(now: Date) async {}

    func stop() async {}
}
