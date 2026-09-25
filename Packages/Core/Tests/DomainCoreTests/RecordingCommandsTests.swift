//  RecordingCommandsTests — MEE-420 часть 3, план MEE-410, группа В (К10-К12): команды
//  записи `AppFacadeImpl.startRecording`/`stopRecording` на прямых фейках портов
//  (`FakeSessionCoordinator`, `FakePermissionsPort`), не `FakeAppFacade` (план MEE-410, §0).
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
        let sessionCoordinator: FakeSessionCoordinator
    }

    private func makeFacade(permissions permissionsOverride: FakePermissionsPort? = nil) -> Fixture {
        let repositories = InMemoryRepositories()
        let permissions = permissionsOverride
            ?? FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: epoch)
        let sessionCoordinator = FakeSessionCoordinator()
        let clock = ManualClock(now: epoch)
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            permissions: permissions,
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: sessionCoordinator,
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

        let startCommands = fixture.sessionCoordinator.recordedCommands.filter {
            if case .startRecording = $0 { return true }
            return false
        }
        XCTAssertTrue(
            startCommands.isEmpty,
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

        XCTAssertTrue(
            fixture.sessionCoordinator.recordedCommands.isEmpty,
            "без права SessionCoordinator не должен вызываться вовсе"
        )
    }

    // MARK: - К12 (инв. 11): stopRecording на неизвестной/уже остановленной записи — не портит состояние

    func test_k12_stopRecordingUnknownOrAlreadyStoppedIsNoop() async throws {
        let fixture = makeFacade()
        let recordingId = UUID()
        fixture.sessionCoordinator.fail(.stopRecording, with: .noRecordingInProgress(recordingId: recordingId))

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
}
