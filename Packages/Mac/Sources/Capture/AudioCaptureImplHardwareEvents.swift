//  AudioCaptureImpl+HardwareEvents — реакция на события шва. Инварианты 5, 9, 11, 12, 13.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API

import DomainCore
import Foundation

extension AudioCaptureImpl {

    /// Зовётся швом на своей очереди при подписке, оформленной в `buildSession`.
    func handleHardwareEvent(_ event: HardwareEvent) {
        guard case .running(let session) = currentSessionPhase() else { return }
        switch event {
        case .microphoneChanged(let handle, let atHostTime):
            guard case .systemDefault = session.currentInputSelection else { return }
            beginRebuild(session, reason: .rebuild, newMicrophone: handle, atHostTime: atHostTime)
        case .microphoneFormatChanged(_, let atHostTime):
            beginRebuild(session, reason: .rebuild, newMicrophone: nil, atHostTime: atHostTime)
            emit(.inputFormatChanged(from: session.request.micFormat, to: session.request.micFormat))
        case .tapInvalidated(let atHostTime):
            beginRebuild(session, reason: .sourceGone, newMicrophone: nil, atHostTime: atHostTime)
        case .aggregateDied(let atHostTime):
            beginRebuild(session, reason: .sourceGone, newMicrophone: nil, atHostTime: atHostTime)
        case .willSleep(let atHostTime):
            handleSleep(session, atHostTime: atHostTime)
        case .didWake(let atHostTime):
            handleWake(session, atHostTime: atHostTime)
        case .processesChanged(let processes, let atHostTime):
            recordProcesses(session, processes: processes, atHostTime: atHostTime)
        }
    }

    private func handleSleep(_ session: CaptureSessionState, atHostTime: UInt64) {
        let atMs = session.referenceTrack?.positionMs ?? 0
        if let marker = try? RecordingManifest.Marker(kind: .sleep, atMs: atMs, detail: nil) {
            session.markers.append(marker)
        }
        beginRebuild(session, reason: .sleep, newMicrophone: nil, atHostTime: atHostTime)
    }

    private func handleWake(_ session: CaptureSessionState, atHostTime: UInt64) {
        let atMs = session.referenceTrack?.positionMs ?? 0
        if let marker = try? RecordingManifest.Marker(kind: .wake, atMs: atMs, detail: nil) {
            session.markers.append(marker)
        }
        writeManifest(session, endedAt: nil, isFinalized: false)
    }

    /// Инварианты 12—14: состав захвата — объединение снимков за всю запись, не последний снимок.
    private func recordProcesses(
        _ session: CaptureSessionState, processes: [CaptureProcessDescriptor], atHostTime: UInt64
    ) {
        for process in processes { session.recordCapturedProcess(process) }
        let requestedAppKey = session.request.group?.appKey
        let resolvedBundleIds = processes.compactMap(\.bundleId)
        let containsUnrequested = requestedAppKey != nil
            && processes.contains { $0.bundleId != requestedAppKey && $0.bundleId != nil }
        let atMs = session.referenceTrack?.positionMs ?? 0
        let manifestProcesses = processes.compactMap {
            try? RecordingManifest.CapturedProcess(pid: $0.pid, bundleId: $0.bundleId,
                                                   executableName: $0.executableName)
        }
        emit(.capturedProcessesChanged(.init(
            atMs: atMs, observedAt: Date(), requestedAppKey: requestedAppKey,
            resolvedBundleIds: resolvedBundleIds, processes: manifestProcesses, containsUnrequested: containsUnrequested
        )))
        writeManifest(session, endedAt: nil, isFinalized: false)
    }

    private func currentSessionPhase() -> CapturePhase {
        lock.lock(); defer { lock.unlock() }
        return phase
    }

    /// Инвариант 12: не реже `capturedProcessesPollSeconds`, даже без единого события шва.
    func pollCapturedProcesses() {
        guard case .running(let session) = currentSessionPhase(), let tap = session.tap else { return }
        let processes = gateway.capturedProcesses(tap)
        recordProcesses(session, processes: processes, atHostTime: session.hostOrigin)
    }
}
