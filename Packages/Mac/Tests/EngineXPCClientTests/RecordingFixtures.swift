//  RecordingFixtures — записи и манифесты для C-012 v12 §1.1 (MEE-480): дорожки `pcm-caf`
//  48 000 Гц, как их пишет `capture` в срезе 1, и `isFinalized == false` у каждой записи
//  (C-013 v16, «Поведение»: перекодирования в срезе нет).
//
//  Модуль: engine-xpc (тесты) · Владелец: DEV-2

import Foundation
import DomainCore
import DomainTestKit

enum RecordingFixtures {

    static func systemTrack() throws -> RecordingManifest.Track {
        try RecordingManifest.Track(
            channel: .system, fileName: "audio-system.caf", sampleRate: 48_000, channelCount: 2, format: "pcm-caf"
        )
    }

    static func micTrack() throws -> RecordingManifest.Track {
        try RecordingManifest.Track(
            channel: .mic, fileName: "audio-mic.caf", sampleRate: 48_000, channelCount: 1, format: "pcm-caf"
        )
    }

    /// Манифест с заданными дорожками в заданном порядке; `isFinalized` — как скажет тест
    /// (по умолчанию `false`, штатное состояние среза 1).
    static func manifest(
        recordingId: UUID, tracks: [RecordingManifest.Track], isFinalized: Bool = false
    ) throws -> RecordingManifest {
        let startedAt = Date(timeIntervalSince1970: 1_789_113_600)
        let hasMic = tracks.contains { $0.channel == .mic }
        let micSpan = try RecordingManifest.InputDeviceSpan(
            atMs: 0, present: true, name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice"
        )
        return try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(600),
            tracks: tracks, markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: hasMic ? [micSpan] : [], discontinuities: [], isFinalized: isFinalized
        )
    }

    /// Запись по умолчанию: две дорожки в порядке `[system, mic]`.
    static func record(
        recordingId: UUID, status: RecordingStatus = .finalized, tracks: [RecordingManifest.Track]? = nil
    ) throws -> RecordingRecord {
        let resolved = try tracks ?? [systemTrack(), micTrack()]
        return RecordingRecord(manifest: try manifest(recordingId: recordingId, tracks: resolved), status: status)
    }
}

/// `ModelCatalogPort`, пишущий `resolve`/`beginUse` в общий с `InMemoryRecordingRepository`
/// журнал — порядок «запись раньше модели» (инв. 24) читается одним журналом.
final class LoggingModelCatalog: ModelCatalogPort, Sendable {
    static let portName = "ModelCatalogPort"
    private let base: FakeModelCatalogPort
    private let log: PortCallLog

    init(base: FakeModelCatalogPort, log: PortCallLog) {
        self.base = base
        self.log = log
    }

    func resolve(profileId: String) async throws -> ResolvedProfile {
        log.record(port: Self.portName, method: "resolve(profileId:)", arguments: [profileId])
        return try await base.resolve(profileId: profileId)
    }

    func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken {
        log.record(port: Self.portName, method: "beginUse(_:)")
        return try await base.beginUse(bundles)
    }

    func endUse(_ token: ModelUseToken) async { await base.endUse(token) }
    func refreshCatalog() async throws { try await base.refreshCatalog() }
    func models() async -> [ModelDescriptor] { await base.models() }
    func model(id: String, version: String) async -> ModelDescriptor? { await base.model(id: id, version: version) }
    func state(id: String, version: String) async -> ModelState { await base.state(id: id, version: version) }
    func download(id: String, version: String) async throws { try await base.download(id: id, version: version) }
    func cancelDownload(id: String, version: String) async { await base.cancelDownload(id: id, version: version) }
    func verify(id: String, version: String) async throws { try await base.verify(id: id, version: version) }
    func delete(id: String, version: String) async throws { try await base.delete(id: id, version: version) }
    func diskUsage() async -> [ModelDiskUsage] { await base.diskUsage() }
    func profiles() async -> [TranscriptionProfile] { await base.profiles() }
    func saveProfile(_ profile: TranscriptionProfile) async throws { try await base.saveProfile(profile) }
    func deleteProfile(id: String) async throws { try await base.deleteProfile(id: id) }
    func missingModels(profileId: String) async throws -> [ModelDescriptor] {
        try await base.missingModels(profileId: profileId)
    }
    func events() -> AsyncStream<ModelCatalogEvent> { base.events() }
}
