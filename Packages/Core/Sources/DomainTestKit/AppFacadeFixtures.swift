//  AppFacadeFixtures — десять именованных готовых состояний `FakeAppFacade` для экранов
//  `app-ui`, C-016 §«Фейк для тестов» (v1 семь, v5 добавила три). MEE-420 (слой 2 плана
//  MEE-410). Даёт `app-ui` собрать и протестировать интерфейс Среза 1 до того, как
//  существует хоть один настоящий модуль (storage/движок/calendar-hub).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Значения полей, которых сценарий не называет по существу (адреса, размеры, версии
//  моделей), — заглушки: фикстура доказывает форму состояния, не берётся заменить
//  реалистичные данные, которых контракт от неё не просит.

import Foundation
import DomainCore

public enum AppFacadeFixtures {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 1. Пустое приложение без встреч и без прав

    public static func emptyAppNoMeetingsNoPermissions() -> FakeAppFacade {
        let permissions = snapshot(allGrantedExcept: Dictionary(
            uniqueKeysWithValues: PermissionKind.allCases.map { ($0, PermissionStatus.notDetermined) }
        ))
        let status = AppStatus(
            activeSession: nil, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
            permissionsReady: .notReady, connectors: [], updatedAt: epoch
        )
        return FakeAppFacade(status: status, permissions: permissions, settings: baseSettings())
    }

    // MARK: - 2. Ближайшая встреча через 10 минут

    public static func upcomingMeetingInTenMinutes() -> FakeAppFacade {
        let event = MeetingEventFixtures.oneOnOneZoom
        let item = MeetingListItem(
            meetingId: event.id, title: event.title, start: epoch.addingTimeInterval(600),
            end: epoch.addingTimeInterval(2_400), provider: "zoom", status: .scheduled,
            attendeeCount: event.attendees.count, isCancelled: false,
            hasRecording: false, hasTranscript: false
        )
        let permissions = snapshot(allGrantedExcept: [:])
        let status = AppStatus(
            activeSession: nil, upcoming: [item], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
            permissionsReady: .ready, connectors: [], updatedAt: epoch
        )
        let facade = FakeAppFacade(status: status, permissions: permissions, settings: baseSettings())
        facade.meetingsValue = [item]
        return facade
    }

    // MARK: - 3. Идущая запись

    public static func activeRecording() -> FakeAppFacade {
        let recordingId = UUID()
        let session = ActiveSessionView(
            recordingId: recordingId, meetingId: nil, title: "Созвон без события",
            state: .recording, startedAt: epoch, requestedAppKey: "com.zoom.xos",
            capturedProcesses: [], containsUnrequested: false, micLevel: 0.4, systemLevel: 0.2
        )
        let permissions = snapshot(allGrantedExcept: [:])
        let status = AppStatus(
            activeSession: session, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
            permissionsReady: .ready, connectors: [], updatedAt: epoch
        )
        return FakeAppFacade(status: status, permissions: permissions, settings: baseSettings())
    }

    // MARK: - 4. Встреча с готовым транскриптом на трёх спикеров, один неопознан

    public static func meetingWithTranscriptThreeSpeakersOneUnknown() -> FakeAppFacade {
        let recordingId = UUID()
        let transcriptId = UUID()
        let header = TranscriptHeader(
            id: transcriptId, recordingId: recordingId, fileIndex: 1,
            engine: "gigaam", modelVersion: "v2", language: "ru", createdAt: epoch
        )
        let known1 = SpeakerView(
            cluster: 0, personId: UUID(), displayName: "Иван Петров", confidence: 0.95,
            source: .voiceProfile, isUncertain: false, runnerUpPersonId: nil,
            runnerUpDisplayName: nil, totalMs: 60_000
        )
        let known2 = SpeakerView(
            cluster: 1, personId: UUID(), displayName: "Мария Сидорова", confidence: 0.9,
            source: .oneOnOne, isUncertain: false, runnerUpPersonId: nil,
            runnerUpDisplayName: nil, totalMs: 45_000
        )
        let unknown = SpeakerView(
            cluster: 2, personId: nil, displayName: "Спикер 3", confidence: 0.4,
            source: .micChannel, isUncertain: true, runnerUpPersonId: nil,
            runnerUpDisplayName: nil, totalMs: 10_000
        )
        let segment = SegmentView(
            segmentId: 1, startMs: 0, endMs: 1_000, channel: .mic, cluster: 0,
            personId: known1.personId, speakerDisplayName: known1.displayName,
            text: "Привет всем", textOriginal: nil, words: [], lowConfidenceWordIndexes: [],
            isUserEdited: false
        )
        let transcriptView = TranscriptView(
            header: header, recordingId: recordingId, speakers: [known1, known2, unknown], segments: [segment]
        )
        let permissions = snapshot(allGrantedExcept: [:])
        let status = AppStatus(
            activeSession: nil, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
            permissionsReady: .ready, connectors: [], updatedAt: epoch
        )
        let facade = FakeAppFacade(status: status, permissions: permissions, settings: baseSettings())
        facade.transcriptValue = transcriptView
        facade.latestTranscriptValue = transcriptView
        return facade
    }

    // MARK: - 5. Упавшая задача транскрибации

    public static func failedTranscriptionJob() -> FakeAppFacade {
        let permissions = snapshot(allGrantedExcept: [:])
        let status = AppStatus(
            activeSession: nil, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 1,
            permissionsReady: .ready, connectors: [], updatedAt: epoch
        )
        let job = Job(
            id: UUID(), type: .transcribe,
            payload: .transcribe(recordingId: UUID(), profileId: "default", language: nil),
            status: .failed, priority: 0, attempts: 3, maxAttempts: 3, runAfter: epoch,
            conditions: JobConditions(
                requiresACPower: false, forbidWhileRecording: false,
                maxThermalPressure: .critical, requiresProfileReady: nil
            ),
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil,
            lastError: "engine.serviceCrashed", createdAt: epoch, updatedAt: epoch
        )
        let facade = FakeAppFacade(status: status, permissions: permissions, settings: baseSettings())
        facade.jobsValue = [job]
        return facade
    }

    // MARK: - 6. Коннектор в состоянии needsAuthorization

    public static func connectorNeedsAuthorization() -> FakeAppFacade {
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        let connector = ConnectorHealthView(
            sourceId: sourceId, displayName: "Календарь macOS", isEnabled: true,
            status: .degraded, message: "Требуется повторная авторизация", lastSyncAt: epoch,
            needsAuthorization: true
        )
        let permissions = snapshot(allGrantedExcept: [:])
        let status = AppStatus(
            activeSession: nil, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
            permissionsReady: .ready, connectors: [connector], updatedAt: epoch
        )
        return FakeAppFacade(status: status, permissions: permissions, settings: baseSettings())
    }

    // MARK: - 7. Модель в состоянии paused(bytesOnDisk:)

    public static func modelPaused() -> FakeAppFacade {
        let descriptor = ModelDescriptor(
            id: "gigaam-v3-e2e-ctc-int8", version: "3.0.0", role: .asr, engine: "coreml-gigaam",
            runtime: .coreml, displayName: "GigaAM v3", description: "Русская ASR-модель",
            sizeBytes: 500_000_000, languages: ["ru"],
            files: [ModelFile(
                name: "model.mlpackage", url: URL(string: "https://cdn.example.com/model.mlpackage")!,
                sha256: String(repeating: "a", count: 64), sizeBytes: 500_000_000
            )],
            quantization: "int8", minChip: .m1, minRAMGB: 8, recommendedFor: ["ru"]
        )
        let permissions = snapshot(allGrantedExcept: [:])
        let status = AppStatus(
            activeSession: nil, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
            permissionsReady: .ready, connectors: [], updatedAt: epoch
        )
        let facade = FakeAppFacade(status: status, permissions: permissions, settings: baseSettings())
        facade.modelsValue = [descriptor]
        facade.modelStateValue = .paused(bytesOnDisk: 200_000_000)
        return facade
    }

    // MARK: - 8. Снимок прав: .systemAudioRecording == .unknown, остальные пять выданы (v5)

    public static func permissionsUnknownUntilFirstUse() -> FakeAppFacade {
        let permissions = snapshot(allGrantedExcept: [.systemAudioRecording: .unknown])
        let status = AppStatus(
            activeSession: nil, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
            permissionsReady: .unknownUntilFirstUse, connectors: [], updatedAt: epoch
        )
        return FakeAppFacade(status: status, permissions: permissions, settings: baseSettings())
    }

    // MARK: - 9. Идущая запись с containsUnrequested (v5)

    public static func activeRecordingWithUnrequestedProcess() throws -> FakeAppFacade {
        let recordingId = UUID()
        let unrequested = try RecordingManifest.CapturedProcess(
            pid: 4242, bundleId: "com.other.app", executableName: "Other App"
        )
        let session = ActiveSessionView(
            recordingId: recordingId, meetingId: nil, title: "Созвон без события",
            state: .recording, startedAt: epoch, requestedAppKey: "com.zoom.xos",
            capturedProcesses: [unrequested], containsUnrequested: true, micLevel: 0.4, systemLevel: 0.2
        )
        let permissions = snapshot(allGrantedExcept: [:])
        let status = AppStatus(
            activeSession: session, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
            permissionsReady: .ready, connectors: [], updatedAt: epoch
        )
        return FakeAppFacade(status: status, permissions: permissions, settings: baseSettings())
    }

    // MARK: - 10. Строка настройки, байты которой не читаются (v5)

    public static func unreadableSetting() -> FakeAppFacade {
        let permissions = snapshot(allGrantedExcept: [:])
        let status = AppStatus(
            activeSession: nil, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
            permissionsReady: .ready, connectors: [], updatedAt: epoch
        )
        let facade = FakeAppFacade(status: status, permissions: permissions, settings: baseSettings())
        // Приёмка РП по PR #141 (`111b061b`, п.1): отдельная ошибка только на `settings()` —
        // общий `forcedError` отказывал бы заодно и всем остальным методам фасада, которых
        // эта фикстура не касается.
        facade.settingsError = .settingsUnreadable(key: "recordingPolicy")
        return facade
    }

    // MARK: - Оснастка

    private static func snapshot(allGrantedExcept overrides: [PermissionKind: PermissionStatus]) -> PermissionSnapshot {
        let states = PermissionKind.allCases.map { kind in
            PermissionState(kind: kind, status: overrides[kind] ?? .granted)
        }
        return PermissionSnapshot(states: states, checkedAt: epoch)
    }

    private static func baseSettings() -> AppSettings {
        AppSettings(
            recordingPolicy: .ask, armLeadSeconds: 120, askLeadSeconds: 30,
            missingSignalGraceSeconds: 900, silenceStopSeconds: 300, defaultProfileId: "default",
            processOnACPowerOnly: false, processWhileRecording: false, audioRetentionDays: nil,
            voiceProfilesEnabled: true, notifyParticipants: false, launchAtLogin: false
        )
    }
}
