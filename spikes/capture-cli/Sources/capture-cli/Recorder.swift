import AVFoundation
import AppKit
import CoreAudio
import Foundation

struct RecordOptions {
    var root: URL
    var label = ""
    var pids: [pid_t] = []
    var bundlePrefix: String?
    var responsiblePID: pid_t?
    var bundleIDs: [String] = []       // macOS 26: CATapDescription.bundleIDs
    var processRestore = false         // macOS 26: CATapDescription.processRestoreEnabled
    var seconds: Double?
    var mic = true
    var clock = "mic"                  // mic | output — чей такт у aggregate device
    var followDefaultInput = true      // пересобирать aggregate при смене устройства ввода
    var retap = false                  // пересобирать при появлении/исчезновении подходящих процессов
    var writer = "raw"                 // raw | apple
    var flushMs = 200
    var restTap = false                // диагностика R1: всё, кроме выбранной группы и себя
    var noDriftTap = false             // диагностика R2: второй tap той же группы без drift compensation
    var voiceProcessing = false        // диагностика R6: параллельно микрофон через AVAudioEngine VP
    var vpDucking = "default"
    var vpDelay = 0.0                  // секунд от начала записи до включения VP: до него — замер без VP
}

/// Одна сборка aggregate device: taps + микрофон + IO-процедура.
final class CaptureSession {
    var taps: [(kind: TrackKind, id: AudioObjectID, uuid: UUID, channels: Int)] = []
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var micID: AudioObjectID?
    var micUID: String?
    var micName: String?
    var micChannels = 0
    var rate: Double = 0
    var layout: [Int] = []
    var routes: [(kind: TrackKind, bufferIndex: Int, channels: Int)] = []
    var processes: [AudioProcess] = []
    var io: IOContext?
    var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var tornDown = false

    func start() throws {
        guard let io else { return }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, inputTime, _, _ in
            io.handle(input, inputTime)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    func teardown() {
        tornDown = true
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, nil, block)
        }
        listeners = []
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        // taps принадлежат Recorder и переживают пересборку aggregate device
    }
}

final class Recorder {
    let options: RecordOptions
    let recordingId = UUID()
    let directory: URL
    private let control = DispatchQueue(label: "capture.control")
    private let writerQueue = DispatchQueue(label: "capture.writer", qos: .userInitiated)
    private let log: EventLog

    private var tracks: [TrackKind: Track] = [:]
    private var session: CaptureSession?
    private var taps: [(kind: TrackKind, id: AudioObjectID, uuid: UUID, channels: Int)] = []
    private var tapProcesses: [AudioProcess] = []
    private var recreateTapsOnRebuild = false
    private var hostOrigin: UInt64 = 0
    private var startedAt: Date?
    private var markers: [RecordingManifest.Marker] = []
    private var inputDevices: [RecordingManifest.InputDeviceSpan] = []
    private var captured: [RecordingManifest.CapturedProcess] = []
    private var pendingBreak: PendingBreak?
    private var pendingRebuild: DispatchWorkItem?
    private var stopping = false
    private var lastStatsHost: UInt64 = 0
    private var overloads = 0
    private var knownProcesses: [AudioObjectID: AudioProcess] = [:]
    private var knownDevices: Set<String> = []
    private var timers: [DispatchSourceTimer] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var activity: NSObjectProtocol?
    private var vpEngine: AVAudioEngine?
    private var vpFirstHost: UInt64 = 0
    private var vpChannelsChecked = false
    private var vpScratch: UnsafeMutablePointer<Float>?

    private struct PendingBreak {
        let atMs: Int
        let reason: String
        let oldMicUID: String?
        let oldMicName: String?
        let oldRate: Double
        let fileMinusHostMs: Double
        let teardownMs: Double
        let requestedHost: UInt64
    }

    init(options: RecordOptions) throws {
        self.options = options
        directory = options.root.appendingPathComponent("recordings").appendingPathComponent(recordingId.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = try EventLog(url: directory.appendingPathComponent("events.log"))
    }

    // MARK: запуск

    func run() -> Never {
        print("recording_dir=\(directory.path)")
        log.event("start", ["label": options.label, "pid": ProcessInfo.processInfo.processIdentifier,
                            "bundleId": Bundle.main.bundleIdentifier ?? "-", "writer": options.writer,
                            "flushMs": options.flushMs, "clock": options.clock,
                            "micPermission": micPermission(), "os": ProcessInfo.processInfo.operatingSystemVersionString])
        if options.mic, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            // Не ждём ответа: первый прогон показал, что без ответа пользователя requestAccess не завершается (50 мин).
            let asked = nowHost()
            AVCaptureDevice.requestAccess(for: .audio) { [self] _ in
                log.event("mic_permission_answer", ["status": micPermission(),
                                                    "waitedMs": (hostTimeSeconds(nowHost()) - hostTimeSeconds(asked)) * 1000])
            }
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "MEE-8 capture spike")
        installSystemListeners()
        installSignalHandlers()
        control.async { [self] in
            do {
                // --vp-delay < 0: VP включается до сборки aggregate, чтобы микрофон уже был в режиме VP.
                if options.voiceProcessing, options.vpDelay < 0 { startVoiceProcessing() }
                try startSession(reason: "start")
            } catch {
                log.event("fatal", ["error": "\(error)"])
                exit(2)
            }
        }
        startTimer(queue: control, intervalMs: 100) { [weak self] in self?.tick() }
        startTimer(queue: writerQueue, intervalMs: options.flushMs) { [weak self] in self?.flush() }
        if let seconds = options.seconds {
            control.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop(reason: "time limit") }
        }
        RunLoop.main.run()
        exit(0)
    }

    private func micPermission() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    // MARK: сборка сессии

    private func resolveProcesses() -> [AudioProcess] {
        let all = AudioProcess.all()
        var selected: [AudioProcess] = []
        selected += all.filter { options.pids.contains($0.pid) }
        if let prefix = options.bundlePrefix { selected += all.filter { ($0.bundleID ?? "").hasPrefix(prefix) } }
        if let responsible = options.responsiblePID { selected += all.filter { $0.responsiblePID == responsible } }
        var seen = Set<AudioObjectID>()
        return selected.filter { seen.insert($0.object).inserted }
    }

    /// Taps живут дольше aggregate device: пересборка из-за микрофона их не трогает (замер: пересоздание tap в момент
    /// смены формата микрофона возвращало id 0 по ~1,3 с на попытку, разрыв записи — 27 с).
    private func ensureTaps(recreate: Bool) throws {
        if !recreate, !taps.isEmpty { return }
        destroyTaps()
        let processes = resolveProcesses()
        if processes.isEmpty && options.bundleIDs.isEmpty {
            throw HALError(status: -1, what: "нет подходящих процессов в kAudioHardwarePropertyProcessObjectList")
        }
        let objects = processes.map(\.object)
        var created: [(kind: TrackKind, id: AudioObjectID, uuid: UUID, channels: Int)] = []
        do {
            let main = try makeTap(kind: .system, processes: objects, excluding: false)
            created.append((.system, main.0, main.1, main.2))
            if options.noDriftTap {
                let extra = try makeTap(kind: .systemNoDrift, processes: objects, excluding: false)
                created.append((.systemNoDrift, extra.0, extra.1, extra.2))
            }
            if options.restTap {
                var excluded = objects
                if let own = HAL.processObject(pid: getpid()) { excluded.append(own) }
                let rest = try makeTap(kind: .rest, processes: excluded, excluding: true)
                created.append((.rest, rest.0, rest.1, rest.2))
            }
        } catch {
            for tap in created { AudioHardwareDestroyProcessTap(tap.id) }
            throw error
        }
        taps = created
        tapProcesses = processes
    }

    private func destroyTaps() {
        for tap in taps { AudioHardwareDestroyProcessTap(tap.id) }
        taps = []
    }

    private func makeTap(kind: TrackKind, processes: [AudioObjectID], excluding: Bool) throws -> (AudioObjectID, UUID, Int) {
        func makeDescription() -> CATapDescription {
            let description = excluding
                ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
                : CATapDescription(stereoMixdownOfProcesses: processes)
            if !options.bundleIDs.isEmpty, !excluding {
                if #available(macOS 26.0, *) {
                    description.bundleIDs = options.bundleIDs
                    description.isProcessRestoreEnabled = options.processRestore
                }
            }
            description.uuid = UUID()
            description.name = "meetforme-spike-\(kind.rawValue)"
            description.muteBehavior = .unmuted
            description.isPrivate = true
            return description
        }
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var description = makeDescription()
        var attemptsMs: [Double] = []
        // Замер: создание tap может вернуть noErr и id 0. Каждая попытка — с новым UUID.
        while tapID == kAudioObjectUnknown && attemptsMs.count < 10 {
            if !attemptsMs.isEmpty { usleep(100_000); description = makeDescription() }
            let started = nowHost()
            try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap(\(kind.rawValue))")
            attemptsMs.append((hostTimeSeconds(nowHost()) - hostTimeSeconds(started)) * 1000)
        }
        if attemptsMs.count > 1 || tapID == kAudioObjectUnknown {
            log.event("tap_create_retried", ["kind": kind.rawValue, "attemptsMs": attemptsMs, "ok": tapID != kAudioObjectUnknown])
        }
        guard tapID != kAudioObjectUnknown else {
            throw HALError(status: -1, what: "AudioHardwareCreateProcessTap(\(kind.rawValue)) вернул id 0 \(attemptsMs.count) раз")
        }
        let format = try HAL.get(tapID, kAudioTapPropertyFormat,
                                 initial: AudioStreamBasicDescription())
        log.event("tap_created", ["kind": kind.rawValue, "tapID": tapID, "uuid": description.uuid.uuidString,
                                  "rate": format.mSampleRate, "channels": format.mChannelsPerFrame,
                                  "formatFlags": format.mFormatFlags, "processObjects": processes,
                                  "excluding": excluding, "bundleIDs": options.bundleIDs,
                                  "permissionProbe": probeTapPermission(tapID),
                                  "descriptionFromHAL": describeTap(tapID)])
        return (tapID, description.uuid, Int(format.mChannelsPerFrame))
    }

    /// Описание tap, как его хранит HAL после создания.
    private func describeTap(_ tapID: AudioObjectID) -> [String: Any] {
        var address = propertyAddress(kAudioTapPropertyDescription)
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        var value: Unmanaged<CATapDescription>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0) }
        guard status == noErr, let description = value?.takeRetainedValue() else { return ["error": status] }
        var result: [String: Any] = ["processes": description.processes, "exclusive": description.isExclusive,
                                     "mixdown": description.isMixdown, "mono": description.isMono,
                                     "private": description.isPrivate, "mute": description.muteBehavior.rawValue]
        if #available(macOS 26.0, *) {
            result["bundleIDs"] = description.bundleIDs
            result["processRestoreEnabled"] = description.isProcessRestoreEnabled
        }
        return result
    }

    /// Публичного API проверки права AudioCapture нет. Повторная запись kAudioTapPropertyDescription без права
    /// возвращает kAudioDevicePermissionsError ('!hog') — так проверяет Chromium (catap_audio_input_stream.mm).
    private func probeTapPermission(_ tapID: AudioObjectID) -> String {
        var address = propertyAddress(kAudioTapPropertyDescription)
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        var value: Unmanaged<CATapDescription>?
        let getStatus = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0) }
        guard getStatus == noErr, let description = value?.takeRetainedValue() else {
            return "get failed \(getStatus) '\(fourCC(UInt32(bitPattern: getStatus)))'"
        }
        var reference: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(description)
        let setStatus = withUnsafeMutablePointer(to: &reference) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, size, $0)
        }
        return setStatus == noErr ? "granted (set ok)" : "set \(setStatus) '\(fourCC(UInt32(bitPattern: setStatus)))'"
    }

    private func buildSession(reason: String, recreateTaps: Bool) throws -> CaptureSession {
        let started = nowHost()
        try ensureTaps(recreate: recreateTaps)
        let session = CaptureSession()
        session.processes = tapProcesses
        session.taps = taps

        do {
            if options.mic, let mic = HAL.defaultInput() {
                session.micID = mic
                session.micUID = HAL.deviceUID(mic)
                session.micName = HAL.deviceName(mic)
                session.micChannels = HAL.streamChannels(mic, scope: kAudioObjectPropertyScopeInput).first ?? 0
            }

            var subDevices: [[String: Any]] = []
            var mainUID: String?
            if options.clock == "output" || session.micUID == nil,
               let output = HAL.defaultOutput(), let outputUID = HAL.deviceUID(output) {
                subDevices.append([kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: 0])
                mainUID = outputUID
            }
            if let micUID = session.micUID {
                subDevices.append([kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: mainUID == nil ? 0 : 1])
                if mainUID == nil { mainUID = micUID }
            }
            let tapList: [[String: Any]] = session.taps.map {
                [kAudioSubTapUIDKey: $0.uuid.uuidString, kAudioSubTapDriftCompensationKey: $0.kind == .systemNoDrift ? 0 : 1]
            }
            let aggregateUID = "meetforme-spike-\(UUID().uuidString)"
            var composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MeetForMe capture spike",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceIsStackedKey: 0,
                kAudioAggregateDeviceTapAutoStartKey: 0,
                kAudioAggregateDeviceSubDeviceListKey: subDevices,
                kAudioAggregateDeviceTapListKey: tapList,
            ]
            if let mainUID { composition[kAudioAggregateDeviceMainSubDeviceKey] = mainUID }
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &session.aggregateID),
                      "AudioHardwareCreateAggregateDevice")

            session.rate = HAL.nominalRate(session.aggregateID)
            session.layout = HAL.streamChannels(session.aggregateID, scope: kAudioObjectPropertyScopeInput)

            // Раскладка буферов IO: сначала входные потоки саб-устройств по порядку списка, затем taps по порядку.
            var index = 0
            for sub in subDevices {
                guard let uid = sub[kAudioSubDeviceUIDKey] as? String, let device = HAL.device(uid: uid) else { continue }
                let streams = HAL.streamChannels(device, scope: kAudioObjectPropertyScopeInput)
                if uid == session.micUID, !streams.isEmpty { session.routes.append((.mic, index, streams[0])) }
                index += streams.count
            }
            for tap in session.taps {
                session.routes.append((tap.kind, index, tap.channels))
                index += 1
            }
            if index != session.layout.count {
                log.event("layout_mismatch", ["expectedBuffers": index, "aggregateLayout": session.layout])
                // Запасной вариант: taps — последние потоки.
                let tapStart = session.layout.count - session.taps.count
                session.routes = session.routes.map { route in
                    guard let tapIndex = session.taps.firstIndex(where: { $0.kind == route.kind }) else { return route }
                    return (route.kind, tapStart + tapIndex, route.channels)
                }
            }
        } catch {
            session.teardown()
            throw error
        }

        log.event("session_built", [
            "reason": reason,
            "aggregateID": session.aggregateID,
            "rate": session.rate,
            "layout": session.layout,
            "routes": session.routes.map { "\($0.kind.rawValue)@\($0.bufferIndex)x\($0.channels)" },
            "clock": options.clock,
            "mic": session.micID.map(HAL.describeDevice) ?? [:],
            "micLatency": session.micID.map { HAL.latency($0, scope: kAudioObjectPropertyScopeInput) } ?? [:],
            "aggregateLatencyIn": HAL.latency(session.aggregateID, scope: kAudioObjectPropertyScopeInput),
            "output": HAL.defaultOutput().map(HAL.describeDevice) ?? [:],
            "processes": session.processes.map(describe),
            "tapsRecreated": recreateTaps,
            "buildMs": (hostTimeSeconds(nowHost()) - hostTimeSeconds(started)) * 1000,
        ])
        return session
    }

    private func startSession(reason: String, recreateTaps: Bool = false) throws {
        let session = try buildSession(reason: reason, recreateTaps: recreateTaps)
        try writerQueue.sync {
            for route in session.routes {
                if let track = tracks[route.kind] {
                    track.configureSession(rate: session.rate, channels: route.channels)
                    track.awaitingAlignment = hostOrigin != 0
                } else {
                    tracks[route.kind] = try Track(kind: route.kind, directory: directory, rate: session.rate,
                                                   channels: route.channels, writer: options.writer)
                }
            }
        }
        session.io = IOContext(routes: session.routes.compactMap { route in
            tracks[route.kind].map { IOContext.Route(bufferIndex: route.bufferIndex, ring: $0.ring, channels: route.channels) }
        })
        installSessionListeners(session)
        do {
            let before = nowHost()
            try session.start()
            log.event("session_started", ["startCallMs": (hostTimeSeconds(nowHost()) - hostTimeSeconds(before)) * 1000,
                                          "permissionProbe": session.taps.first.map { probeTapPermission($0.id) } ?? "-"])
        } catch {
            session.teardown()
            throw error
        }
        self.session = session
        for process in session.processes where !captured.contains(where: { $0.pid == process.pid }) {
            // HAL отдаёт "" для процесса без бандла: в манифест это идёт как nil.
            captured.append(.init(pid: process.pid, bundleId: process.bundleID.flatMap { $0.isEmpty ? nil : $0 },
                                  executableName: process.executableName))
        }
    }

    // MARK: такт управления

    private func tick() {
        guard !stopping, let session, let io = session.io else { return }
        let snapshot = io.snapshot()
        if snapshot.firstHost != 0 {
            if hostOrigin == 0 {
                establishOrigin(session: session, firstHost: snapshot.firstHost)
            } else if let pending = pendingBreak {
                alignAfterBreak(session: session, firstHost: snapshot.firstHost, pending: pending)
            }
        }
        if vpFirstHost != 0, let track = tracks[.micVP], track.awaitingAlignment, hostOrigin != 0 {
            let offset = hostTimeSeconds(vpFirstHost) - hostTimeSeconds(hostOrigin)
            writerQueue.sync {
                try? track.writeSilence(frames: Int64((offset * track.rate).rounded()))
                track.awaitingAlignment = false
            }
            log.event("vp_aligned", ["offsetMs": offset * 1000])
        }
        let now = nowHost()
        if hostOrigin != 0, hostTimeSeconds(now) - hostTimeSeconds(lastStatsHost) >= 10 {
            lastStatsHost = now
            logStats(session: session)
        }
    }

    private func establishOrigin(session: CaptureSession, firstHost: UInt64) {
        hostOrigin = firstHost
        lastStatsHost = firstHost
        let age = hostTimeSeconds(nowHost()) - hostTimeSeconds(firstHost)
        startedAt = ManifestJSON.roundedToMs(Date().addingTimeInterval(-age))
        if session.micID != nil {
            inputDevices = [.init(atMs: 0, name: session.micName, uid: session.micUID)]
        }
        writeManifest(endedAt: nil)
        log.event("origin", ["startedAt": ManifestJSON.formatDate(startedAt!), "firstCallbackAgeMs": age * 1000])
        if options.voiceProcessing, options.vpDelay >= 0 {
            control.asyncAfter(deadline: .now() + options.vpDelay) { [weak self] in self?.startVoiceProcessing() }
        }
    }

    private func alignAfterBreak(session: CaptureSession, firstHost: UInt64, pending: PendingBreak) {
        pendingBreak = nil
        let position = hostTimeSeconds(firstHost) - hostTimeSeconds(hostOrigin)
        var gaps: [String: Double] = [:]
        writerQueue.sync {
            for route in session.routes {
                guard let track = tracks[route.kind] else { continue }
                let gap = Int64((position * track.rate).rounded()) - track.framesWritten
                if gap > 0 { try? track.writeSilence(frames: gap) }
                gaps[route.kind.rawValue] = Double(gap) / track.rate * 1000
                track.awaitingAlignment = false
            }
        }
        let gapMs = gaps[TrackKind.mic.rawValue] ?? gaps[TrackKind.system.rawValue] ?? 0
        let totalMs = (hostTimeSeconds(firstHost) - hostTimeSeconds(pending.requestedHost)) * 1000
        let detail = "aggregate rebuilt (\(pending.reason)); gap \(Int(gapMs.rounded())) ms filled with silence; "
            + "rate \(Int(pending.oldRate))->\(Int(session.rate))"
        markers.append(.init(kind: .discontinuity, atMs: pending.atMs, detail: detail))
        if session.micUID != pending.oldMicUID {
            if let last = inputDevices.last, last.atMs == pending.atMs {
                // Две смены подряд без единого записанного кадра между ними: инв. 9 требует различных atMs.
                inputDevices.removeLast()
                markers.removeAll { $0.kind == .deviceChanged && $0.atMs == pending.atMs }
                log.event("device_change_collapsed", ["atMs": pending.atMs])
            }
            if session.micID != nil {
                inputDevices.append(.init(atMs: pending.atMs, name: session.micName, uid: session.micUID))
                markers.append(.init(kind: .deviceChanged, atMs: pending.atMs,
                                     detail: "\(pending.oldMicUID ?? "none") -> \(session.micUID ?? "none")"))
            } else {
                log.event("mic_lost_not_expressible", ["atMs": pending.atMs])
            }
        }
        markers.sort { $0.atMs < $1.atMs }
        writeManifest(endedAt: nil)
        log.event("rebuild_done", ["reason": pending.reason, "atMs": pending.atMs, "gapsMs": gaps,
                                   "requestToFirstBufferMs": totalMs, "teardownMs": pending.teardownMs,
                                   "fileMinusHostClockBeforeBreakMs": pending.fileMinusHostMs,
                                   "oldMic": pending.oldMicUID ?? "none", "newMic": session.micUID ?? "none",
                                   "newRate": session.rate])
    }

    private func logStats(session: CaptureSession) {
        guard let io = session.io else { return }
        let snapshot = io.snapshot(resetPeaks: true)
        var peaks: [String: Double] = [:]
        for (index, route) in session.routes.enumerated() where index < snapshot.peaks.count {
            peaks[route.kind.rawValue] = (dBFS(snapshot.peaks[index]) * 10).rounded() / 10
        }
        let hostSpan = hostTimeSeconds(snapshot.lastHost) - hostTimeSeconds(snapshot.firstHost)
        let sampleSpan = Double(snapshot.frames - Int64(snapshot.lastFrameCount)) / max(session.rate, 1)
        var dropped: [String: Int] = [:]
        var positions: [String: Double] = [:]
        writerQueue.sync {
            for (kind, track) in tracks {
                dropped[kind.rawValue] = track.ring.dropped
                positions[kind.rawValue] = Double(track.framesWritten) / track.rate
            }
        }
        let recordingSeconds = hostTimeSeconds(snapshot.lastHost) - hostTimeSeconds(hostOrigin)
        log.event("stats", [
            "tS": (recordingSeconds * 10).rounded() / 10,
            "callbacks": snapshot.callbacks,
            "sampleTimeJumps": snapshot.sampleTimeJumps,
            "jumpedFrames": snapshot.jumpedFrames,
            "channelMismatches": snapshot.channelMismatches,
            "observedChannels": snapshot.observedChannels,
            "sessionSamplesMinusHostMs": (sampleSpan - hostSpan) * 1000,
            "aggregateActualRate": HAL.actualRate(session.aggregateID),
            "overloads": overloads,
            "peakDBFS": peaks,
            "droppedSamples": dropped,
            "fileSeconds": positions,
            "tapIsRunningOutput": session.processes.map { AudioProcess(object: $0.object).isRunningOutput },
            "permissionProbe": session.taps.first.map { probeTapPermission($0.id) } ?? "-",
        ])
        if let systemIndex = session.routes.firstIndex(where: { $0.kind == .system }),
           systemIndex < snapshot.peaks.count, snapshot.peaks[systemIndex] == 0,
           session.processes.contains(where: { AudioProcess(object: $0.object).isRunningOutput }) {
            log.event("tap_silent_while_process_outputs", ["hint": "нет права System Audio Recording или tap невалиден"])
        }
    }

    // MARK: пересборка

    private func scheduleRebuild(reason: String, delayMs: Int = 400, recreateTaps: Bool = false) {
        pendingRebuild?.cancel()
        let requested = nowHost()
        recreateTapsOnRebuild = recreateTapsOnRebuild || recreateTaps
        let item = DispatchWorkItem { [weak self] in self?.rebuild(reason: reason, requestedHost: requested) }
        pendingRebuild = item
        control.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
    }

    private func rebuild(reason: String, requestedHost: UInt64) {
        guard !stopping else { return }
        let oldMicUID = session?.micUID ?? inputDevices.last?.uid
        let oldMicName = session?.micName ?? inputDevices.last?.name
        let oldRate = session?.rate ?? tracks[.system]?.rate ?? 0
        let teardownStart = nowHost()
        var fileMinusHostMs = 0.0
        if let old = session {
            let snapshot = old.io?.snapshot()
            old.teardown()
            session = nil
            if let snapshot, hostOrigin != 0 {
                let hostPosition = hostTimeSeconds(snapshot.lastHost) + Double(snapshot.lastFrameCount) / max(old.rate, 1)
                    - hostTimeSeconds(hostOrigin)
                writerQueue.sync { flushTracks() }
                if let reference = tracks[.mic] ?? tracks[.system] {
                    fileMinusHostMs = (Double(reference.framesWritten) / reference.rate - hostPosition) * 1000
                }
            }
        }
        let teardownMs = (hostTimeSeconds(nowHost()) - hostTimeSeconds(teardownStart)) * 1000
        let reference = tracks[.mic] ?? tracks[.system]
        let atMs = reference.map { Int((Double($0.framesWritten) / $0.rate * 1000).rounded()) } ?? 0
        do {
            if pendingBreak == nil {
                pendingBreak = PendingBreak(atMs: atMs, reason: reason, oldMicUID: oldMicUID, oldMicName: oldMicName,
                                            oldRate: oldRate, fileMinusHostMs: fileMinusHostMs, teardownMs: teardownMs,
                                            requestedHost: requestedHost)
            }
            try startSession(reason: reason, recreateTaps: recreateTapsOnRebuild)
            recreateTapsOnRebuild = false
        } catch {
            log.event("rebuild_failed", ["reason": reason, "error": "\(error)"])
            scheduleRebuild(reason: reason, delayMs: 1000)
        }
    }

    // MARK: слушатели

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             session: CaptureSession? = nil, _ handler: @escaping () -> Void) {
        var address = propertyAddress(selector, scope)
        // Уведомление, поставленное в очередь до teardown, приходит уже после него: от снесённой сессии — игнорируем.
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            if session?.tornDown == true { return }
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, control, block)
        if status == noErr { session?.listeners.append((object, address, block)) }
    }

    private func installSystemListeners() {
        knownProcesses = Dictionary(uniqueKeysWithValues: AudioProcess.all().map { ($0.object, $0) })
        knownDevices = Set(HAL.devices().compactMap(HAL.deviceUID))

        addListener(HAL.system, kAudioHardwarePropertyDefaultInputDevice) { [self] in
            let device = HAL.defaultInput()
            log.event("default_input_changed", ["device": device.map(HAL.describeDevice) ?? [:],
                                                "sessionMic": session?.micUID ?? "none"])
            if options.followDefaultInput, options.mic, device.flatMap(HAL.deviceUID) != session?.micUID {
                scheduleRebuild(reason: "default input changed")
            }
        }
        addListener(HAL.system, kAudioHardwarePropertyDefaultOutputDevice) { [self] in
            log.event("default_output_changed", ["device": HAL.defaultOutput().map(HAL.describeDevice) ?? [:]])
        }
        addListener(HAL.system, kAudioHardwarePropertyDevices) { [self] in
            let now = Set(HAL.devices().compactMap(HAL.deviceUID))
            log.event("devices_changed", ["added": Array(now.subtracting(knownDevices)),
                                          "removed": Array(knownDevices.subtracting(now))])
            knownDevices = now
        }
        addListener(HAL.system, kAudioHardwarePropertyProcessObjectList) { [self] in
            let current = Dictionary(uniqueKeysWithValues: AudioProcess.all().map { ($0.object, $0) })
            let added = current.keys.filter { knownProcesses[$0] == nil }.compactMap { current[$0] }
            let removed = knownProcesses.keys.filter { current[$0] == nil }.compactMap { knownProcesses[$0] }
            knownProcesses = current
            let tapped = Set(session?.processes.map(\.object) ?? [])
            log.event("process_list_changed", ["added": added.map(describe), "removed": removed.map(describe),
                                               "tappedGone": removed.filter { tapped.contains($0.object) }.map(\.pid)])
            if options.retap, Set(resolveProcesses().map(\.object)) != tapped {
                scheduleRebuild(reason: "tapped process set changed", recreateTaps: true)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.control.async { self?.addMarker(.sleep, detail: nil); self?.log.event("will_sleep", [:]) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.control.async {
                self?.addMarker(.wake, detail: nil)
                self?.log.event("did_wake", [:])
                self?.scheduleRebuild(reason: "wake", delayMs: 1500)
            }
        }
    }

    private func installSessionListeners(_ session: CaptureSession) {
        addListener(session.aggregateID, kAudioDevicePropertyDeviceIsAlive, session: session) { [self] in
            log.event("aggregate_alive_changed", ["alive": HAL.isAlive(session.aggregateID)])
            if !HAL.isAlive(session.aggregateID) { scheduleRebuild(reason: "aggregate died", delayMs: 100) }
        }
        addListener(session.aggregateID, kAudioDeviceProcessorOverload, session: session) { [self] in
            overloads += 1
        }
        addListener(session.aggregateID, kAudioDevicePropertyNominalSampleRate, session: session) { [self] in
            log.event("aggregate_rate_changed", ["rate": HAL.nominalRate(session.aggregateID)])
        }
        addListener(session.aggregateID, kAudioAggregateDevicePropertyActiveSubDeviceList, session: session) { [self] in
            log.event("aggregate_subdevices_changed", [:])
        }
        addListener(session.aggregateID, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput,
                    session: session) { [self] in
            let layout = HAL.streamChannels(session.aggregateID, scope: kAudioObjectPropertyScopeInput)
            log.event("aggregate_stream_config_changed", ["old": session.layout, "new": layout,
                                                          "rate": HAL.nominalRate(session.aggregateID)])
            if layout != session.layout { scheduleRebuild(reason: "aggregate stream configuration changed", delayMs: 200) }
        }
        if let mic = session.micID {
            addListener(mic, kAudioDevicePropertyDeviceIsAlive, session: session) { [self] in
                log.event("mic_alive_changed", ["uid": session.micUID ?? "?", "alive": HAL.isAlive(mic)])
                if !HAL.isAlive(mic) { scheduleRebuild(reason: "mic died", delayMs: 100) }
            }
            addListener(mic, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput,
                        session: session) { [self] in
                let channels = HAL.streamChannels(mic, scope: kAudioObjectPropertyScopeInput)
                log.event("mic_stream_config_changed", ["uid": session.micUID ?? "?", "channels": channels,
                                                        "rate": HAL.nominalRate(mic)])
                // Замер: слушатель на aggregate при этом не срабатывает, срабатывает только на микрофоне.
                if channels.first != session.micChannels {
                    scheduleRebuild(reason: "mic stream configuration changed \(session.micChannels)->\(channels.first ?? 0)", delayMs: 200)
                }
            }
        }
        for tap in session.taps {
            addListener(tap.id, kAudioTapPropertyFormat, session: session) { [self] in
                log.event("tap_format_changed", ["kind": tap.kind.rawValue])
            }
        }
    }

    private func installSignalHandlers() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: control)
            source.setEventHandler { [weak self] in self?.stop(reason: "signal \(number)") }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: voice processing (R6)

    private func startVoiceProcessing() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            if options.vpDucking == "min" {
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
            let format = input.outputFormat(forBus: 0)
            // Первый прогон R6: все 7 каналов выхода VP побайтно одинаковые по уровню — пишем канал 0 как моно.
            let track = try writerQueue.sync {
                try Track(kind: .micVP, directory: directory, rate: format.sampleRate, channels: 1, writer: options.writer)
            }
            track.awaitingAlignment = true
            writerQueue.sync { tracks[.micVP] = track }
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 48000 * 8)
            vpScratch = scratch
            input.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] buffer, time in
                guard let self, let channels = buffer.floatChannelData, self.hostOrigin != 0 else { return }
                if self.vpFirstHost == 0, time.isHostTimeValid { self.vpFirstHost = time.hostTime }
                let frames = min(Int(buffer.frameLength), 48000 * 8)
                let count = Int(buffer.format.channelCount)
                if !self.vpChannelsChecked, count > 1 {
                    self.vpChannelsChecked = true
                    var maxDiff: Float = 0
                    for channel in 1..<count {
                        for frame in 0..<frames { maxDiff = max(maxDiff, abs(channels[channel][frame] - channels[0][frame])) }
                    }
                    self.log.event("vp_channels_check", ["channels": count, "maxAbsDiffVsCh0": Double(maxDiff)])
                }
                scratch.update(from: channels[0], count: frames)
                track.ring.write(scratch, samples: frames)
            }
            engine.prepare()
            try engine.start()
            vpEngine = engine
            log.event("vp_started", ["rate": format.sampleRate, "channels": format.channelCount,
                                     "ducking": options.vpDucking,
                                     "vpEnabled": input.isVoiceProcessingEnabled])
        } catch {
            log.event("vp_failed", ["error": "\(error)"])
        }
    }

    // MARK: запись и остановка

    private func flush() {
        flushTracks()
    }

    private func flushTracks() {
        for track in tracks.values {
            do {
                try track.drain()
                track.sink.sync()
            } catch {
                log.event("write_failed", ["track": track.kind.rawValue, "error": "\(error)"])
            }
        }
    }

    private func addMarker(_ kind: RecordingManifest.MarkerKind, detail: String?) {
        guard hostOrigin != 0 else { return }
        let reference = writerQueue.sync { tracks[.mic] ?? tracks[.system] }
        let atMs = reference.map { Int((Double($0.framesWritten) / $0.rate * 1000).rounded()) } ?? 0
        markers.append(.init(kind: kind, atMs: max(atMs, markers.last?.atMs ?? 0), detail: detail))
        writeManifest(endedAt: nil)
    }

    private func writeManifest(endedAt: Date?) {
        guard let startedAt else { return }
        var manifestTracks: [RecordingManifest.Track] = []
        for (kind, channel) in [(TrackKind.mic, RecordingManifest.Channel.mic), (.system, .system)] {
            guard let track = tracks[kind] else { continue }
            manifestTracks.append(.init(channel: channel, fileName: kind.fileName, sampleRate: Int(track.rate),
                                        channelCount: track.channels, format: "pcm-caf"))
        }
        let manifest = RecordingManifest(recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
                                         startedAt: startedAt, endedAt: endedAt, tracks: manifestTracks,
                                         markers: markers, capturedProcesses: captured, inputDevices: inputDevices,
                                         isFinalized: false)
        if let violation = manifest.firstViolation() { log.event("manifest_violation", ["violation": violation]) }
        do {
            try ManifestJSON.writeAtomically(manifest, to: directory)
        } catch {
            log.event("manifest_write_failed", ["error": "\(error)"])
        }
    }

    private func stop(reason: String) {
        guard !stopping else { return }
        stopping = true
        let endHost = nowHost()
        if let session { logStats(session: session) }
        session?.teardown()
        destroyTaps()
        vpEngine?.stop()
        writerQueue.sync {
            flushTracks()
            for track in tracks.values { track.sink.close() }
        }
        if let startedAt, hostOrigin != 0 {
            let ended = ManifestJSON.roundedToMs(startedAt.addingTimeInterval(hostTimeSeconds(endHost) - hostTimeSeconds(hostOrigin)))
            writeManifest(endedAt: ended)
        }
        var files: [String: Double] = [:]
        for (kind, track) in tracks { files[kind.rawValue] = Double(track.framesWritten) / track.rate }
        log.event("stop", ["reason": reason, "fileSeconds": files, "markers": markers.count])
        print("stopped: \(reason)")
        exit(0)
    }

    private func startTimer(queue: DispatchQueue, intervalMs: Int, _ handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
        timer.setEventHandler(handler: handler)
        timer.resume()
        timers.append(timer)
    }
}

func describe(_ process: AudioProcess) -> [String: Any] {
    [
        "object": process.object, "pid": process.pid, "bundleID": process.bundleID ?? "-",
        "exe": process.executableName ?? "-", "ppid": process.parentPID, "responsiblePID": process.responsiblePID,
        "out": process.isRunningOutput, "in": process.isRunningInput,
    ]
}

/// Журнал событий: JSON Lines на диск (fsync на каждой строке — журнал нужен именно после kill -9) и кратко в stderr.
final class EventLog {
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func event(_ name: String, _ fields: [String: Any]) {
        var record = fields
        record["event"] = name
        record["wall"] = ManifestJSON.formatDate(Date())
        record["hostS"] = hostTimeSeconds(nowHost())
        guard JSONSerialization.isValidJSONObject(record),
              var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            FileHandle.standardError.write("[event \(name)] not serializable: \(fields)\n".data(using: .utf8)!)
            return
        }
        data.append(0x0A)
        lock.lock()
        handle.write(data)
        try? handle.synchronize()
        lock.unlock()
        FileHandle.standardError.write(data)
    }
}
