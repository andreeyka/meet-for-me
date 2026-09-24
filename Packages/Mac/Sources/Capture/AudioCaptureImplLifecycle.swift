//  AudioCaptureImpl+Lifecycle — stop, pause, resume, setInput. Инварианты 1, 19, 21, 22.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API

import DomainCore
import Foundation

extension AudioCaptureImpl {

    public func stop() async throws -> RecordingManifest {
        let session = try beginStopping()
        return try await finishStop(session)
    }

    public func pause() async throws {
        let session = try currentSession()
        guard !session.isPaused else { return }
        session.isPaused = true
        let atMs = session.referenceTrack?.positionMs ?? 0
        session.markers.append(try RecordingManifest.Marker(kind: .pause, atMs: atMs, detail: nil))
        writeManifest(session, endedAt: nil, isFinalized: false)
    }

    public func resume() async throws {
        let session = try currentSession()
        guard session.isPaused else { return }
        session.isPaused = false
        let atMs = session.referenceTrack?.positionMs ?? 0
        session.markers.append(try RecordingManifest.Marker(kind: .resume, atMs: atMs, detail: nil))
        writeManifest(session, endedAt: nil, isFinalized: false)
    }

    public func setInput(_ selection: InputSelection) async throws {
        let session = try currentSession()
        try await reconfigureMicrophone(session, to: selection, reason: .rebuild)
    }

    func beginStopping() throws -> CaptureSessionState {
        lock.lock(); defer { lock.unlock() }
        guard case .running(let session) = phase else { throw CaptureError.notRunning }
        phase = .stopping
        return session
    }

    private func finishStop(_ session: CaptureSessionState) async throws -> RecordingManifest {
        pollHandle?.stop()
        lock.lock(); pollHandle = nil; lock.unlock()
        session.subscription?.cancel()
        gateway.teardownAggregate(session.aggregate)
        if let tap = session.tap { gateway.releaseTap(tap) }
        if let microphone = session.microphone { gateway.releaseMicrophone(microphone) }
        session.powerToken?.end()
        session.micTrack?.finalize()
        session.systemTrack?.finalize()

        let elapsedSeconds = Double(session.referenceTrack?.framesWritten ?? 0)
            / Double(session.referenceTrack?.sampleRate ?? 1)
        let endedAt = session.startedAt.addingTimeInterval(max(elapsedSeconds, 0))
        do {
            let manifest = try buildManifest(session, endedAt: endedAt, isFinalized: false)
            try ManifestWriter.writeAtomically(manifest, to: session.directory)
            resetToIdle()
            emit(.stopped(manifest))
            return manifest
        } catch {
            resetToIdle()
            throw CaptureError.systemUnavailable(message: "\(error)")
        }
    }
}
