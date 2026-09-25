//  FakeAppFacade — публичный доступ к состоянию и результатам команд, под замком.
//  Разведено в отдельный файл по объёму (`type_body_length`), не по смыслу — см. заголовок
//  `FakeAppFacade.swift`. Каждое свойство — тонкая обёртка над приватным полем хранения,
//  `get`/`set` обе идут через `locked { }` (приёмка РП по PR #141, `111b061b`, п.4).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)

import Foundation
import DomainCore

extension FakeAppFacade {

    // MARK: - Состояние чтения (задаётся тестом)

    public var statusValue: AppStatus {
        get { locked { storedStatusValue } }
        set { locked { storedStatusValue = newValue } }
    }
    public var meetingsValue: [MeetingListItem] {
        get { locked { storedMeetingsValue } }
        set { locked { storedMeetingsValue = newValue } }
    }
    public var meetingDetailValue: MeetingDetail? {
        get { locked { storedMeetingDetailValue } }
        set { locked { storedMeetingDetailValue = newValue } }
    }
    public var transcriptValue: TranscriptView? {
        get { locked { storedTranscriptValue } }
        set { locked { storedTranscriptValue = newValue } }
    }
    public var latestTranscriptValue: TranscriptView? {
        get { locked { storedLatestTranscriptValue } }
        set { locked { storedLatestTranscriptValue = newValue } }
    }
    public var searchHitsValue: [SearchHit] {
        get { locked { storedSearchHitsValue } }
        set { locked { storedSearchHitsValue = newValue } }
    }
    public var permissionSnapshotValue: PermissionSnapshot {
        get { locked { storedPermissionSnapshotValue } }
        set { locked { storedPermissionSnapshotValue = newValue } }
    }
    public var modelsValue: [ModelDescriptor] {
        get { locked { storedModelsValue } }
        set { locked { storedModelsValue = newValue } }
    }
    public var modelStateValue: ModelState {
        get { locked { storedModelStateValue } }
        set { locked { storedModelStateValue = newValue } }
    }
    public var profilesValue: [TranscriptionProfile] {
        get { locked { storedProfilesValue } }
        set { locked { storedProfilesValue = newValue } }
    }
    public var jobsValue: [Job] {
        get { locked { storedJobsValue } }
        set { locked { storedJobsValue = newValue } }
    }
    public var settingsValue: AppSettings {
        get { locked { storedSettingsValue } }
        set { locked { storedSettingsValue = newValue } }
    }

    // MARK: - Возвращаемые значения команд (задаются тестом app-ui — приёмка `111b061b`, п.2)

    public var startRecordingResult: UUID {
        get { locked { storedStartRecordingResult } }
        set { locked { storedStartRecordingResult = newValue } }
    }
    public var syncCalendarsResult: [CalendarSyncResult] {
        get { locked { storedSyncCalendarsResult } }
        set { locked { storedSyncCalendarsResult = newValue } }
    }
    public var beginConnectorAuthResult: AuthChallenge {
        get { locked { storedBeginConnectorAuthResult } }
        set { locked { storedBeginConnectorAuthResult = newValue } }
    }
    public var completeConnectorAuthResult: String? {
        get { locked { storedCompleteConnectorAuthResult } }
        set { locked { storedCompleteConnectorAuthResult = newValue } }
    }
    public var connectorSettingsSchemaResult: Data {
        get { locked { storedConnectorSettingsSchemaResult } }
        set { locked { storedConnectorSettingsSchemaResult = newValue } }
    }
    public var connectorHealthTemplate: ConnectorHealthTemplate {
        get { locked { storedConnectorHealthTemplate } }
        set { locked { storedConnectorHealthTemplate = newValue } }
    }
    public var requestPermissionResult: PermissionRequestOutcome {
        get { locked { storedRequestPermissionResult } }
        set { locked { storedRequestPermissionResult = newValue } }
    }
    public var retranscribeResult: UUID {
        get { locked { storedRetranscribeResult } }
        set { locked { storedRetranscribeResult = newValue } }
    }
    public var retryJobResult: UUID {
        get { locked { storedRetryJobResult } }
        set { locked { storedRetryJobResult = newValue } }
    }
    public var createPersonAndAssignResult: UUID {
        get { locked { storedCreatePersonAndAssignResult } }
        set { locked { storedCreatePersonAndAssignResult = newValue } }
    }
    public var exportResult: URL {
        get { locked { storedExportResult } }
        set { locked { storedExportResult = newValue } }
    }

    // MARK: - Управление из теста

    /// Заставить любую команду и почти любое чтение бросить эту ошибку; `nil` снимает
    /// отказ. Исключение — `settings()`: у него отдельная `settingsError` (приёмка
    /// `111b061b`, п.1), проверяемая первой, чтобы фикстура «настройка не читается» не
    /// заодно ломала остальные методы фасада.
    public var forcedError: AppFacadeError? {
        get { locked { storedForcedError } }
        set { locked { storedForcedError = newValue } }
    }

    /// Ошибка, которую бросает только `settings()`; `nil` — `settings()` смотрит на
    /// `forcedError`, как раньше.
    public var settingsError: AppFacadeError? {
        get { locked { storedSettingsError } }
        set { locked { storedSettingsError = newValue } }
    }
}
