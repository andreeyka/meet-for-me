//  CoreAudioGateway — реальная реализация шва `HardwareGateway` поверх Core Audio HAL.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Устройство и числа — по спайку MEE-8 (`spikes/capture-cli/Sources/capture-cli/HAL.swift`,
//  `Recorder.swift`): tap создаётся один раз на сеанс и переживает пересборку (инвариант 4,
//  замер — пересоздание в момент смены формата давало `noErr` с нулевым id 20 раз подряд по
//  ~1,3 с, разрыв 27,4 с); пересобирается только aggregate device (инвариант 5, уведомление
//  приходит на микрофон, не на сам aggregate); компенсация дрейфа включена на каждой сборке
//  безусловно (инвариант 6). `voiceProcessing`/`restTap`/`noDriftTap` спайка сюда не перенесены:
//  контракт запрещает первое (инвариант 8), два прочих были диагностикой спайка, не поведением
//  порта.

import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import DomainCore
import Foundation

final class CoreAudioGateway: HardwareGateway, @unchecked Sendable {

    private let lock = NSLock()
    private var openTaps: [UUID: AudioObjectID] = [:]
    private var eventHandlers: [UUID: @Sendable (HardwareEvent) -> Void] = [:]
    private var aggregates: [UUID: AggregateRuntime] = [:]
    private var sleepObserversInstalled = false

    func requestSystemAudioTap(for group: ProcessGroup?) async -> TapAttempt {
        guard let group else { return .permissionDenied }
        let objects = group.pids.compactMap(HALObject.processObject(pid:))
        guard !objects.isEmpty else { return .systemUnavailable(message: "нет процессов группы в HAL") }
        let outcome = await Task.detached { HALTap.create(for: objects) }.value
        guard case .success(let object) = outcome else {
            if case .failure(let message) = outcome { return .systemUnavailable(message: message) }
            return .permissionDenied
        }
        let token = UUID()
        lock.lock()
        openTaps[token] = object
        lock.unlock()
        return .created(TapHandle(token: token))
    }

    func requestMicrophone(_ selection: InputSelection) async -> MicrophoneAttempt {
        guard selection != .none else { return .permissionDenied }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted { return .permissionDenied }
        if status == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            guard granted else { return .permissionDenied }
        }
        guard let device = HALObject.resolveInputDevice(selection) else {
            if case .uid(let uid) = selection { return .deviceUnavailable(uid: uid) }
            return .systemUnavailable(message: "устройства ввода по умолчанию нет")
        }
        let channels = HALObject.inputChannelCount(device.id)
        return .opened(MicrophoneHandle(uid: device.uid, name: device.name, channelCount: max(channels, 1)))
    }

    func releaseTap(_ handle: TapHandle) {
        lock.lock()
        let object = openTaps.removeValue(forKey: handle.token)
        lock.unlock()
        if let object { AudioHardwareDestroyProcessTap(object) }
    }

    func releaseMicrophone(_ handle: MicrophoneHandle) {
        // Микрофонный вход не держит собственного объекта вне aggregate device — сборка и
        // разборка происходят в `buildAggregate`/`teardownAggregate`; закрывать здесь нечего.
    }

    func buildAggregate(
        tap: TapHandle?, microphone: MicrophoneHandle?, onBuffer: @escaping @Sendable (HardwareBuffer) -> Void
    ) throws -> AggregateHandle {
        var tapObject: AudioObjectID?
        if let tap {
            lock.lock()
            tapObject = openTaps[tap.token]
            lock.unlock()
        }
        let runtime = try AggregateRuntime.build(
            tapObject: tapObject, microphoneUID: microphone?.uid, onBuffer: onBuffer,
            onEvent: { [weak self] event in self?.broadcast(event) }
        )
        let handle = AggregateHandle()
        lock.lock()
        aggregates[handle.token] = runtime
        lock.unlock()
        return handle
    }

    func teardownAggregate(_ handle: AggregateHandle) {
        lock.lock()
        let runtime = aggregates.removeValue(forKey: handle.token)
        lock.unlock()
        runtime?.teardown()
    }

    func capturedProcesses(_ tap: TapHandle) -> [CaptureProcessDescriptor] {
        lock.lock()
        let object = openTaps[tap.token]
        lock.unlock()
        guard let object else { return [] }
        return HALTap.describedProcesses(object)
    }

    func subscribeEvents(_ handler: @escaping @Sendable (HardwareEvent) -> Void) -> HardwareSubscription {
        let id = UUID()
        lock.lock()
        eventHandlers[id] = handler
        lock.unlock()
        installSleepObserversIfNeeded()
        return Subscription(id: id, owner: self)
    }

    /// Сон/пробуждение — `NSWorkspace`, единственный способ узнать о них на пользовательском
    /// процессе (спайк MEE-8: `willSleepNotification`/`didWakeNotification`). Один раз на жизнь
    /// шлюза: подписка не привязана к конкретному сеансу (инвариант 23, шов переживает сеансы).
    private func installSleepObserversIfNeeded() {
        lock.lock()
        let alreadyInstalled = sleepObserversInstalled
        sleepObserversInstalled = true
        lock.unlock()
        guard !alreadyInstalled else { return }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.broadcast(.willSleep(atHostTime: CoreAudioGateway.nowMs()))
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.broadcast(.didWake(atHostTime: CoreAudioGateway.nowMs()))
        }
    }

    private static func nowMs() -> UInt64 {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return mach_absolute_time() }
        return mach_absolute_time() * UInt64(info.numer) / UInt64(info.denom) / 1_000_000
    }

    fileprivate func broadcast(_ event: HardwareEvent) {
        lock.lock()
        let handlers = Array(eventHandlers.values)
        lock.unlock()
        for handler in handlers { handler(event) }
    }

    private final class Subscription: HardwareSubscription {
        let id: UUID
        weak var owner: CoreAudioGateway?
        init(id: UUID, owner: CoreAudioGateway) { self.id = id; self.owner = owner }
        func cancel() {
            owner?.lock.lock()
            owner?.eventHandlers.removeValue(forKey: id)
            owner?.lock.unlock()
        }
    }
}
