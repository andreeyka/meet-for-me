//  AudioCaptureImpl+Start — гонка права, сборка сеанса. Инварианты 1, 2, 3, 6, 14, 15, 16, 21, 25.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API

import DomainCore
import Foundation

extension AudioCaptureImpl {

    /// Гонит право системного звука и микрофона против их пределов (инвариант 15) и либо
    /// собирает сеанс целиком, либо не создаёт ни одного файла (инвариант 2).
    func performStart(_ request: CaptureRequest) async throws -> (CaptureSessionState, CaptureStarted) {
        var tap: TapHandle?
        var microphone: MicrophoneHandle?
        do {
            tap = try await acquireTap(for: request.group)
            microphone = try await acquireMicrophone(request.input, releasing: tap)
        } catch {
            if let tap { gateway.releaseTap(tap) }
            throw error
        }
        do {
            return try await buildSession(request: request, tap: tap, microphone: microphone)
        } catch {
            if let tap { gateway.releaseTap(tap) }
            if let microphone { gateway.releaseMicrophone(microphone) }
            throw error
        }
    }

    private func acquireTap(for group: ProcessGroup?) async throws -> TapHandle? {
        guard let group else { return nil }
        let raced = await race(
            timeoutSeconds: AudioCaptureLimits.systemAudioPromptWaitSeconds, deadline: deadline
        ) { [gateway] in
            await gateway.requestSystemAudioTap(for: group)
        }
        switch raced.outcome {
        case .timedOut:
            handleLateTap(raced.pending)
            throw CaptureError.systemAudioPromptTimedOut(waitedSeconds: AudioCaptureLimits.systemAudioPromptWaitSeconds)
        case .value(.permissionDenied):
            emit(.permissionObserved(kind: .systemAudioRecording, status: .denied))
            throw CaptureError.systemAudioDenied
        case .value(.systemUnavailable(let message)):
            throw CaptureError.systemUnavailable(message: message)
        case .value(.created(let handle)):
            emit(.permissionObserved(kind: .systemAudioRecording, status: .granted))
            return handle
        }
    }

    private func acquireMicrophone(
        _ selection: InputSelection, releasing tap: TapHandle?
    ) async throws -> MicrophoneHandle? {
        guard selection != .none else { return nil }
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
            return handle
        }
    }

    /// §«Право на системный звук», п. 3: ответ, пришедший после предела, всё равно дожидается.
    /// Когда он придёт — исход публикуется `permissionObserved` (ровно тот же путь, что и у
    /// ответа, успевшего в предел), а если tap всё-таки создался, он уничтожается: сеанса, которому
    /// он принадлежал бы, уже нет. `.systemUnavailable` не несёт исхода права — событие не про него.
    func handleLateTap(_ pending: Task<TapAttempt, Never>) {
        Task { [weak self, gateway] in
            switch await pending.value {
            case .created(let handle):
                self?.emit(.permissionObserved(kind: .systemAudioRecording, status: .granted))
                gateway.releaseTap(handle)
            case .permissionDenied:
                self?.emit(.permissionObserved(kind: .systemAudioRecording, status: .denied))
            case .systemUnavailable:
                break
            }
        }
    }

    /// §«Микрофонный промпт», п. 3: тот же приём, микрофонный вход закрывается, если открылся
    /// с опозданием. Событие `permissionObserved` про микрофон контракт не заводит (инв. 16).
    func handleLateMicrophone(_ pending: Task<MicrophoneAttempt, Never>) {
        Task { [gateway] in
            if case .opened(let handle) = await pending.value {
                gateway.releaseMicrophone(handle)
            }
        }
    }

    /// Собирает aggregate device, открывает треки, берёт токен `PowerPort` — либо не создаёт
    /// ни одного файла (инвариант 2). Любой отказ на любом шаге откатывает уже открытые файлы.
    private func buildSession(
        request: CaptureRequest, tap: TapHandle?, microphone: MicrophoneHandle?
    ) async throws -> (CaptureSessionState, CaptureStarted) {
        let session = CaptureSessionState(
            recordingId: request.recordingId, meetingId: request.meetingId, directory: request.directory,
            request: request, startedAt: Date(), aggregate: AggregateHandle()
        )
        let openedFiles = try openTracks(request: request, tap: tap, microphone: microphone, into: session)
        session.tap = tap
        session.microphone = microphone
        session.captureGroupKey = request.group?.appKey
        // Инвариант 21: токен берётся ДО сборки aggregate, а не после — отказ сборки тоже отказ
        // "после того, как токен мог быть взят", и обязан его снять (К23).
        session.powerToken = await power.beginActivity(reason: .recording, label: "capture")
        do {
            try attachMicrophoneSpan(microphone, to: session)
            try attachAggregate(tap: tap, microphone: microphone, to: session)
        } catch {
            session.powerToken?.end()
            rollback(openedFiles, in: request.directory)
            throw error
        }

        session.subscription = gateway.subscribeEvents { [weak self] event in
            self?.handleHardwareEvent(event)
        }
        installPowerEventsIfNeeded()
        if let tap {
            for process in gateway.capturedProcesses(tap) { session.recordCapturedProcess(process) }
        }

        do {
            let started = CaptureStarted(
                recordingId: session.recordingId, startedAt: session.startedAt,
                tracks: try session.manifestTracks(), captureGroupKey: session.captureGroupKey
            )
            writeManifest(session, endedAt: nil, isFinalized: false)
            return (session, started)
        } catch {
            session.powerToken?.end()
            gateway.teardownAggregate(session.aggregate)
            session.subscription?.cancel()
            rollback(openedFiles, in: request.directory)
            throw CaptureError.systemUnavailable(message: "\(error)")
        }
    }

    private func openTracks(
        request: CaptureRequest, tap: TapHandle?, microphone: MicrophoneHandle?, into session: CaptureSessionState
    ) throws -> [TrackFile] {
        var openedFiles: [TrackFile] = []
        do {
            if tap != nil {
                let track = try openTrack(.system, request: request)
                openedFiles.append(track)
                session.systemTrack = track
            }
            if microphone != nil {
                let track = try openTrack(.mic, request: request)
                openedFiles.append(track)
                session.micTrack = track
            }
            return openedFiles
        } catch {
            rollback(openedFiles, in: request.directory)
            throw CaptureError.directoryUnusable(message: "\(error)")
        }
    }

    private func attachMicrophoneSpan(_ microphone: MicrophoneHandle?, to session: CaptureSessionState) throws {
        guard let microphone else { return }
        session.currentMicrophoneUID = microphone.uid
        session.currentMicrophoneName = microphone.name
        session.currentMicrophoneChannelCount = microphone.channelCount
        do {
            let span = try RecordingManifest.InputDeviceSpan(atMs: 0, present: true, name: microphone.name,
                                                              uid: microphone.uid)
            session.inputDevices.append(span)
        } catch {
            throw CaptureError.systemUnavailable(message: "\(error)")
        }
    }

    private func attachAggregate(
        tap: TapHandle?, microphone: MicrophoneHandle?, to session: CaptureSessionState
    ) throws {
        do {
            session.aggregate = try gateway.buildAggregate(tap: tap, microphone: microphone) { [weak self] buffer in
                self?.handleBuffer(buffer)
            }
        } catch {
            throw CaptureError.systemUnavailable(message: "\(error)")
        }
    }

    private func openTrack(_ channel: RecordingManifest.Channel, request: CaptureRequest) throws -> TrackFile {
        let format = channel == .mic ? request.micFormat : request.systemFormat
        return try TrackFile(directory: request.directory, channel: channel, format: format)
    }

    private func rollback(_ files: [TrackFile], in directory: URL) {
        for file in files {
            file.finalize()
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.fileName))
        }
    }
}

extension CaptureSessionState {
    func recordCapturedProcess(_ process: CaptureProcessDescriptor) {
        let key = "\(process.pid)"
        capturedProcesses[key] = try? .init(pid: process.pid, bundleId: process.bundleId,
                                            executableName: process.executableName)
    }
}
