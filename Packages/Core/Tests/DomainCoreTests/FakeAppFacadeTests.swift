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

    /// Табличный тест (приёмка РП по PR #141, `111b061b`, п.5): прежняя версия проверяла
    /// три метода из ~27 бросающих команд — здесь названы все.
    func test_k44_forcedErrorThrownByAnyCommand() async throws {
        let facade = Self.makeFacade()
        facade.forcedError = .notAllowed(reason: "тестовый отказ")

        for entry in Self.allThrowingCommands(on: facade) {
            do {
                try await entry.call()
                XCTFail("\(entry.name) должен бросить forcedError")
            } catch AppFacadeError.notAllowed(let reason) {
                XCTAssertEqual(reason, "тестовый отказ", entry.name)
            } catch {
                XCTFail("\(entry.name): неожиданная ошибка \(error)")
            }
        }
    }

    /// Все ~27 бросающих команд `AppFacade`, каждая обёрнута вызовом на заданном фейке —
    /// оснастка табличного теста выше.
    private static func allThrowingCommands(
        on facade: FakeAppFacade
    ) -> [(name: String, call: () async throws -> Void)] {
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        let exportDirectory = URL(fileURLWithPath: "/tmp")
        let profile = TranscriptionProfile(
            id: "p1", displayName: "Профиль", language: "ru", asrModelId: "asr",
            vadModelId: nil, diarizationModelId: nil, embeddingModelId: nil,
            diarization: DiarizationParameters(expectedSpeakers: nil, clusteringThreshold: 0.5, minSegmentMs: 500),
            isBuiltIn: false
        )
        return [
            ("startRecording", { _ = try await facade.startRecording(meetingId: nil) }),
            ("stopRecording", { try await facade.stopRecording(recordingId: UUID()) }),
            ("skipMeeting", { try await facade.skipMeeting(meetingId: UUID()) }),
            ("setConnectorEnabled", { try await facade.setConnectorEnabled(true, sourceId: sourceId) }),
            ("beginConnectorAuth", { _ = try await facade.beginConnectorAuth(sourceId: sourceId) }),
            ("completeConnectorAuth", {
                _ = try await facade.completeConnectorAuth(sourceId: sourceId, callbackUrl: URL(string: "https://x")!)
            }),
            ("connectorSettingsSchema", { _ = try await facade.connectorSettingsSchema(sourceId: sourceId) }),
            ("configureConnector", { try await facade.configureConnector(sourceId: sourceId, settings: Data()) }),
            ("connectorHealth", { _ = try await facade.connectorHealth(sourceId: sourceId) }),
            ("openPermissionSettings", { try await facade.openPermissionSettings(.microphone) }),
            ("downloadModel", { try await facade.downloadModel(id: "m1", version: "1") }),
            ("deleteModel", { try await facade.deleteModel(id: "m1", version: "1") }),
            ("saveProfile", { try await facade.saveProfile(profile) }),
            ("deleteProfile", { try await facade.deleteProfile(id: "p1") }),
            ("retranscribe", { _ = try await facade.retranscribe(recordingId: UUID(), profileId: "p1") }),
            ("cancelJob", { try await facade.cancelJob(id: UUID()) }),
            ("retryJob", { _ = try await facade.retryJob(id: UUID()) }),
            ("assignSpeaker", { try await facade.assignSpeaker(transcriptId: UUID(), cluster: 0, personId: UUID()) }),
            ("createPersonAndAssign", {
                _ = try await facade.createPersonAndAssign(
                    transcriptId: UUID(), cluster: 0, displayName: "Имя", email: nil
                )
            }),
            ("clearSpeaker", { try await facade.clearSpeaker(transcriptId: UUID(), cluster: 0) }),
            ("editSegmentText", { try await facade.editSegmentText(segmentId: 1, text: "текст") }),
            ("renamePerson", { try await facade.renamePerson(personId: UUID(), displayName: "Имя") }),
            ("forgetVoiceProfile", { try await facade.forgetVoiceProfile(personId: UUID()) }),
            ("deleteRecording", { try await facade.deleteRecording(recordingId: UUID(), deleteFiles: true) }),
            ("deleteMeeting", { try await facade.deleteMeeting(meetingId: UUID()) }),
            ("export", { _ = try await facade.export(meetingId: UUID(), format: .markdown, to: exportDirectory) }),
            ("updateSettings", { try await facade.updateSettings(Self.makeSettings()) })
        ]
    }

    /// Приёмка РП по PR #141 (`111b061b`, п.1): `settingsError` отказывает только
    /// `settings()`, остальные методы фасада им не задеты (в отличие от `forcedError`).
    func test_k44_settingsErrorThrowsOnlyFromSettingsNotOtherMethods() async throws {
        let facade = Self.makeFacade()
        facade.settingsError = .settingsUnreadable(key: "recordingPolicy")

        do {
            _ = try await facade.settings()
            XCTFail("ожидался settingsUnreadable")
        } catch AppFacadeError.settingsUnreadable(let key) {
            XCTAssertEqual(key, "recordingPolicy")
        }

        try await facade.stopRecording(recordingId: UUID())
        _ = try await facade.meetings(from: Date(), to: Date())
        XCTAssertEqual(facade.recordedCommands.count, 1, "stopRecording прошла, settingsError её не коснулась")
    }

    /// Приёмка РП по PR #141 (`111b061b`, п.2): результаты команд теперь публично
    /// настраиваемые — `app-ui` может задать их, не только Core.
    func test_k44_commandResultsAreSettableFromOutsideDomainTestKit() async throws {
        let facade = Self.makeFacade()
        let expected = UUID()
        facade.retranscribeResult = expected

        let returned = try await facade.retranscribe(recordingId: UUID(), profileId: "p1")

        XCTAssertEqual(returned, expected)
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

    /// Приёмка РП по PR #141 (`111b061b`, п.3): `configureConnector`, `saveProfile`,
    /// `updateSettings` записывали не весь аргумент — здесь каждый несёт различающее
    /// значение, отсутствовавшее в записи до правки.
    func test_k44_recordsFullArgumentsForConfigureConnectorSaveProfileAndUpdateSettings() async throws {
        let facade = Self.makeFacade()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        let payload = Data("{\"key\":\"value\"}".utf8)
        let profile = TranscriptionProfile(
            id: "p1", displayName: "Профиль отличимый", language: "ru", asrModelId: "asr",
            vadModelId: nil, diarizationModelId: nil, embeddingModelId: nil,
            diarization: DiarizationParameters(expectedSpeakers: nil, clusteringThreshold: 0.5, minSegmentMs: 500),
            isBuiltIn: false
        )
        let newSettings = AppSettings(
            recordingPolicy: .manual, armLeadSeconds: 1, askLeadSeconds: 2,
            missingSignalGraceSeconds: 3, silenceStopSeconds: 4, defaultProfileId: "distinct-profile",
            processOnACPowerOnly: true, processWhileRecording: true, audioRetentionDays: 7,
            voiceProfilesEnabled: false, notifyParticipants: true, launchAtLogin: true
        )

        try await facade.configureConnector(sourceId: sourceId, settings: payload)
        try await facade.saveProfile(profile)
        try await facade.updateSettings(newSettings)

        let recorded = facade.recordedCommands
        XCTAssertEqual(recorded[0].arguments, [sourceId.rawValue, payload.base64EncodedString()])
        XCTAssertTrue(recorded[1].arguments.first?.contains("Профиль отличимый") == true, "профиль записан целиком")
        XCTAssertTrue(recorded[1].arguments.first?.contains("p1") == true)
        XCTAssertTrue(recorded[2].arguments.first?.contains("distinct-profile") == true, "настройки записаны целиком")
        XCTAssertTrue(recorded[2].arguments.first?.contains("manual") == true)
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

        let emptyStatus = await empty.status()
        let upcomingStatus = await upcoming.status()
        let activeStatus = await active.status()
        let connectorStatus = await connector.status()
        let unknownPermissionStatus = await unknownPermission.status()
        let unrequestedProcessStatus = await unrequestedProcess.status()

        XCTAssertEqual(emptyStatus.permissionsReady, .notReady)
        XCTAssertEqual(emptyStatus.upcoming, [])
        XCTAssertEqual(upcomingStatus.upcoming.count, 1)
        XCTAssertNotNil(activeStatus.activeSession)
        XCTAssertEqual(transcript.transcriptValue?.speakers.count, 3)
        XCTAssertEqual(transcript.transcriptValue?.speakers.filter { $0.personId == nil }.count, 1)
        XCTAssertEqual(failedJob.jobsValue.first?.status, .failed)
        XCTAssertEqual(connectorStatus.connectors.first?.needsAuthorization, true)
        XCTAssertEqual(modelPaused.modelStateValue, .paused(bytesOnDisk: 200_000_000))
        XCTAssertEqual(unknownPermissionStatus.permissionsReady, .unknownUntilFirstUse)
        XCTAssertEqual(unrequestedProcessStatus.activeSession?.containsUnrequested, true)
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
            settings: makeSettings()
        )
    }

    private static func makeSettings() -> AppSettings {
        AppSettings(
            recordingPolicy: .ask, armLeadSeconds: 120, askLeadSeconds: 30,
            missingSignalGraceSeconds: 900, silenceStopSeconds: 300, defaultProfileId: "default",
            processOnACPowerOnly: false, processWhileRecording: false, audioRetentionDays: nil,
            voiceProfilesEnabled: true, notifyParticipants: false, launchAtLogin: false
        )
    }
}
