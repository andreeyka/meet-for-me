//  AudioCaptureImpl+Rebuild — пересборка aggregate device: tap не трогается (инвариант 4),
//  дрейф считается по позиции файла против host time на момент разрыва (§«Оценка ошибки шкалы»).
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API

import DomainCore
import Foundation

extension AudioCaptureImpl {

    /// Начинает пересборку: помечает разрыв как открытый (`pendingRebuild`) и переоткрывает
    /// aggregate device с тем же `tap` — второй вызов `requestSystemAudioTap` за сеанс не
    /// делается никогда (инвариант 4).
    func beginRebuild(
        _ session: CaptureSessionState,
        reason: RecordingManifest.DiscontinuityReason,
        newMicrophone: MicrophoneHandle?,
        atHostTime: UInt64
    ) {
        guard session.pendingRebuild == nil else { return }
        let atMs = session.referenceTrack?.positionMs ?? 0
        let hostPositionMs = session.hostOrigin == 0 ? 0 : Double(atHostTime - session.hostOrigin)
        let pending = CaptureSessionState.PendingRebuild(
            reason: reason, atMs: atMs,
            oldMicrophoneUID: session.currentMicrophoneUID, oldMicrophoneName: session.currentMicrophoneName,
            requestedHostTime: atHostTime,
            fileMinusHostMs: Double(atMs) - hostPositionMs
        )
        session.pendingRebuild = pending
        gateway.teardownAggregate(session.aggregate)
        if let newMicrophone {
            if let old = session.microphone { gateway.releaseMicrophone(old) }
            session.microphone = newMicrophone
            session.currentMicrophoneUID = newMicrophone.uid
            session.currentMicrophoneName = newMicrophone.name
            session.currentMicrophoneChannelCount = newMicrophone.channelCount
        }
        do {
            session.aggregate = try gateway.buildAggregate(
                tap: session.tap, microphone: session.microphone, driftCompensation: true
            ) { [weak self] buffer in
                self?.handleBuffer(buffer)
            }
            // Инвариант 12(б): «при каждой пересборке aggregate device» — дословно контракт.
            if let tap = session.tap {
                recordProcesses(session, processes: gateway.capturedProcesses(tap), atHostTime: atHostTime)
            }
        } catch {
            // Пересобрать не удалось сразу — попытка не повторяется автоматически в PR1;
            // разрыв остаётся открытым до следующего события, которое переоткроет aggregate.
        }
    }

    /// Первый буфер новой сборки называет позицию, на которую ставится разрыв: тишина
    /// дописывается до неё, чтобы шкала файла продолжила совпадать с host time (см. `TrackFile`).
    func resolveRebuild(
        _ session: CaptureSessionState, pending: CaptureSessionState.PendingRebuild, firstBufferHostTime: UInt64
    ) {
        session.pendingRebuild = nil
        let gapMs = Int(max(0, Int64(bitPattern: firstBufferHostTime) - Int64(bitPattern: pending.requestedHostTime)))
        for track in [session.micTrack, session.systemTrack].compactMap({ $0 }) {
            let frames = Int(Double(gapMs) / 1000.0 * Double(track.sampleRate))
            guard frames > 0 else { continue }
            try? track.append([Float](repeating: 0, count: frames * track.channelCount))
        }
        let scaleErrorMs = ScaleError.compute(reason: pending.reason, fileMinusHostMs: pending.fileMinusHostMs)
        guard let discontinuity = try? RecordingManifest.Discontinuity(
            atMs: pending.atMs, gapMs: gapMs, scaleErrorMs: scaleErrorMs, reason: pending.reason
        ) else { return }
        if pending.reason == .sleep {
            // `handleSleep` уже добавил и маркер `.discontinuity`, и предварительную запись (с
            // `gapMs: 0`, инвариант 15 требует пару немедленно, §«Сон») — здесь заменяем ту
            // запись точной, а не добавляем вторую: на один сон — один разрыв на диске.
            if let idx = session.discontinuities.lastIndex(where: { $0.atMs == pending.atMs && $0.reason == .sleep }) {
                session.discontinuities[idx] = discontinuity
            } else {
                session.discontinuities.append(discontinuity)
            }
        } else {
            session.discontinuities.append(discontinuity)
            let detail = "aggregate rebuilt (\(pending.reason.rawValue))"
            guard let marker = try? RecordingManifest.Marker(kind: .discontinuity, atMs: pending.atMs, detail: detail)
            else { return }
            session.markers.append(marker)
        }
        if session.currentMicrophoneUID != pending.oldMicrophoneUID {
            recordDeviceChange(session, atMs: pending.atMs, from: pending.oldMicrophoneUID)
        }
        writeManifest(session, endedAt: nil, isFinalized: false)
        emit(.discontinuity(.init(atMs: pending.atMs, gapMs: gapMs, scaleErrorMs: scaleErrorMs, reason: pending.reason,
                                  fileMinusHostMs: Int(pending.fileMinusHostMs.rounded()))))
    }

    private func recordDeviceChange(_ session: CaptureSessionState, atMs: Int, from oldUID: String?) {
        if let last = session.inputDevices.last, last.atMs == atMs {
            session.inputDevices.removeLast()
            session.markers.removeAll { $0.kind == .deviceChanged && $0.atMs == atMs }
        }
        let span = try? RecordingManifest.InputDeviceSpan(
            atMs: atMs, present: session.currentMicrophoneUID != nil,
            name: session.currentMicrophoneName, uid: session.currentMicrophoneUID
        )
        guard let span else { return }
        session.inputDevices.append(span)
        let detail = "\(oldUID ?? "none") -> \(session.currentMicrophoneUID ?? "none")"
        guard let marker = try? RecordingManifest.Marker(kind: .deviceChanged, atMs: atMs, detail: detail)
        else { return }
        session.markers.append(marker)
        emit(.inputDeviceChanged(span))
    }

    /// `setInput` — явный запрос смены входа от домена (не перечитывание события шва):
    /// микрофон закрывается и открывается заново через `requestMicrophone`, потому что
    /// смена набора входов по требованию проходит тот же путь получения права, что старт.
    func reconfigureMicrophone(_ session: CaptureSessionState, to selection: InputSelection,
                               reason: RecordingManifest.DiscontinuityReason) async throws {
        session.currentInputSelection = selection
        if selection == .none {
            if let microphone = session.microphone {
                gateway.releaseMicrophone(microphone)
            }
            session.microphone = nil
            session.currentMicrophoneUID = nil
            session.currentMicrophoneName = nil
            beginRebuild(session, reason: reason, newMicrophone: nil, atHostTime: currentHostTime(session))
            return
        }
        let raced = await race(
            timeoutSeconds: AudioCaptureLimits.microphonePromptWaitSeconds, deadline: deadline
        ) { [gateway] in
            await gateway.requestMicrophone(selection)
        }
        switch raced.outcome {
        case .timedOut:
            handleLateMicrophone(raced.pending)
            throw CaptureError.microphonePromptTimedOut(waitedSeconds: AudioCaptureLimits.microphonePromptWaitSeconds)
        case .value(.permissionDenied):
            throw CaptureError.microphoneDenied
        case .value(.deviceUnavailable(let uid)):
            throw CaptureError.inputDeviceUnavailable(uid: uid)
        case .value(.systemUnavailable(let message)):
            throw CaptureError.systemUnavailable(message: message)
        case .value(.opened(let handle)):
            beginRebuild(session, reason: reason, newMicrophone: handle, atHostTime: currentHostTime(session))
        }
    }

    func currentHostTime(_ session: CaptureSessionState) -> UInt64 {
        session.hostOrigin + UInt64(session.referenceTrack?.positionMs ?? 0)
    }
}
