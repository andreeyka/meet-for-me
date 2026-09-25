//  FakeAppFacadeTests — К44 перечня MEE-401, план MEE-410 группа Т, MEE-420.
//
//  Класс (3): предмет теста — сам фейк, единственное (вместе с половиной К49, вне
//  Core) исключение из правила «предмет теста — реализация AppFacade» (план MEE-410,
//  §0, правка РП п.1). Проверяет три умения, названные §«Фейк для тестов» C-016
//  дословно: бросить любую `AppFacadeError` из любой команды, записать вызванные
//  команды с аргументами, вручную протолкнуть `AppEvent` — и наличие десяти именованных
//  фикстур `AppFacadeFixtures`.

import XCTest
import DomainCore
import DomainTestKit

final class FakeAppFacadeTests: XCTestCase {

    // MARK: - Умение 1: заставить любую команду бросить любую AppFacadeError

    func test_k44_forcedErrorThrownByAnyCommand() async throws {
        let facade = Self.makeFacade()
        facade.forcedError = .notAllowed(reason: "тестовый отказ")

        await assertThrowsForcedError(try await facade.stopRecording(recordingId: UUID()))
        await assertThrowsForcedError(try await facade.cancelJob(id: UUID()))
        await assertThrowsForcedError(_ = try await facade.settings())
    }

    // MARK: - Умение 2: записать все вызванные команды с аргументами

    func test_k44_recordsCommandsWithArgumentsInOrder() async throws {
        let facade = Self.makeFacade()
        let recordingId = UUID()

        try await facade.stopRecording(recordingId: recordingId)
        _ = try await facade.retranscribe(recordingId: recordingId, profileId: "p1")

        XCTAssertEqual(
            facade.recordedCommands,
            [
                FakeAppFacadeCommand(name: "stopRecording(recordingId:)", arguments: [recordingId.uuidString]),
                FakeAppFacadeCommand(
                    name: "retranscribe(recordingId:profileId:)", arguments: [recordingId.uuidString, "p1"]
                )
            ]
        )
    }

    /// Чтения (`status`, `settings`, …) не записываются — контракт называет именно «команды».
    func test_k44_readsAreNotRecordedAsCommands() async {
        let facade = Self.makeFacade()
        _ = await facade.status()
        _ = try? await facade.settings()
        XCTAssertTrue(facade.recordedCommands.isEmpty)
    }

    // MARK: - Умение 3: вручную протолкнуть любой AppEvent, включая failure с любым AppErrorView

    func test_k44_pushDeliversAnyEventIncludingInternalErrorFailure() async {
        let facade = Self.makeFacade()
        var iterator = facade.events().makeAsyncIterator()

        let errorView = AppErrorView(
            code: "app.internalError", message: "неизвестно", recoverySuggestion: nil, permissionKind: nil
        )
        facade.push(.failure(errorView))
        facade.push(.meetingsChanged)
        facade.finishEvents()

        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()

        XCTAssertEqual(first, .failure(errorView))
        XCTAssertEqual(second, .meetingsChanged)
        XCTAssertNil(third, "поток закрыт finishEvents()")
    }

    // MARK: - AppFacadeFixtures: десять именованных фикстур существуют и различимы

    func test_k44_appFacadeFixturesHasTenNamedStates() async throws {
        let empty = AppFacadeFixtures.emptyAppNoMeetingsNoPermissions()
        let upcoming = AppFacadeFixtures.upcomingMeetingInTenMinutes()
        let active = AppFacadeFixtures.activeRecording()
        let transcript = AppFacadeFixtures.meetingWithTranscriptThreeSpeakersOneUnknown()
        let failedJob = AppFacadeFixtures.failedTranscriptionJob()
        let connector = AppFacadeFixtures.connectorNeedsAuthorization()
        let modelPaused = AppFacadeFixtures.modelPaused()
        let unknownPermission = AppFacadeFixtures.permissionsUnknownUntilFirstUse()
        let unrequestedProcess = try AppFacadeFixtures.activeRecordingWithUnrequestedProcess()
        let unreadable = AppFacadeFixtures.unreadableSetting()

        XCTAssertEqual(await empty.status().permissionsReady, .notReady)
        XCTAssertEqual(await empty.status().upcoming, [])
        XCTAssertEqual(await upcoming.status().upcoming.count, 1)
        XCTAssertNotNil(await active.status().activeSession)
        XCTAssertEqual(transcript.transcriptValue?.speakers.count, 3)
        XCTAssertEqual(transcript.transcriptValue?.speakers.filter { $0.personId == nil }.count, 1)
        XCTAssertEqual(failedJob.jobsValue.first?.status, .failed)
        XCTAssertEqual(await connector.status().connectors.first?.needsAuthorization, true)
        XCTAssertEqual(modelPaused.modelStateValue, .paused(bytesOnDisk: 200_000_000))
        XCTAssertEqual(await unknownPermission.status().permissionsReady, .unknownUntilFirstUse)
        XCTAssertEqual(await unrequestedProcess.status().activeSession?.containsUnrequested, true)
        do {
            _ = try await unreadable.settings()
            XCTFail("ожидался settingsUnreadable")
        } catch AppFacadeError.settingsUnreadable {
            // ожидаемо
        }
    }

    // MARK: - Оснастка

    private static func makeFacade() -> FakeAppFacade {
        FakeAppFacade(
            status: AppStatus(
                activeSession: nil, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
                permissionsReady: .ready, connectors: [], updatedAt: Date(timeIntervalSince1970: 0)
            ),
            permissions: PermissionSnapshot(
                states: PermissionKind.allCases.map { PermissionState(kind: $0, status: .granted) },
                checkedAt: Date(timeIntervalSince1970: 0)
            ),
            settings: AppSettings(
                recordingPolicy: .ask, armLeadSeconds: 120, askLeadSeconds: 30,
                missingSignalGraceSeconds: 900, silenceStopSeconds: 300, defaultProfileId: "default",
                processOnACPowerOnly: false, processWhileRecording: false, audioRetentionDays: nil,
                voiceProfilesEnabled: true, notifyParticipants: false, launchAtLogin: false
            )
        )
    }

    private func assertThrowsForcedError(
        _ expression: @autoclosure () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("ожидался forcedError", file: file, line: line)
        } catch AppFacadeError.notAllowed(let reason) {
            XCTAssertEqual(reason, "тестовый отказ", file: file, line: line)
        } catch {
            XCTFail("неожиданная ошибка: \(error)", file: file, line: line)
        }
    }
}
