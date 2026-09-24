//  Оснастка тестов модуля `capture` — фейковый шов (план MEE-315 §«Шов»).
//
//  * `FakeHardwareGateway` — задаёт исход попытки tap/микрофона (сразу либо «зависнув» до
//    явного `resolveTap(with:)`/`resolveMicrophone(with:)` — виртуальное время шва, план
//    MEE-315), считает вызовы `requestSystemAudioTap`/`buildAggregate` порознь, отдаёт
//    подставной состав захвата, проталкивает `HardwareEvent`, кормит текущий `onBuffer` PCM.
//  * `ManualDeadline` — предел ожидания; по умолчанию «висит» (не спит по-настоящему), тест
//    вызывает `expireNow()` там, где сценарий ждёт таймаута.
//  * `Harness` — порт на подставленном мире, plus вспомогательные конструкторы `CaptureRequest`.

import DomainCore
import DomainTestKit
import Foundation
import XCTest
@testable import Capture

// MARK: - Шов

final class FakeHardwareGateway: HardwareGateway, @unchecked Sendable {

    private let lock = NSLock()
    private var tapContinuations: [CheckedContinuation<TapAttempt, Never>] = []
    private var micContinuations: [CheckedContinuation<MicrophoneAttempt, Never>] = []
    /// MEE-374 (аудит MEE-377): явный gate вместо фикс. паузы, угадывающей момент, когда
    /// `AudioCaptureImpl` реально дошёл до `requestSystemAudioTap`/`requestMicrophone` и
    /// зарегистрировал continuation — `resolveTap`/`resolveMicrophone` до этого момента теряют
    /// разрешение молча (см. их же `pending = []`).
    private var tapRequestedContinuations: [CheckedContinuation<Void, Never>] = []
    private var micRequestedContinuations: [CheckedContinuation<Void, Never>] = []
    /// Тот же довод для позднего пути (К17): `handleLateTap`/`handleLateMicrophone` зовут
    /// `releaseTap`/`releaseMicrophone` из СОБСТВЕННОГО фонового `Task` — сигнал «релиз
    /// действительно случился» вместо угадывания паузой.
    private var tapReleasedContinuations: [CheckedContinuation<Void, Never>] = []
    private var micReleasedContinuations: [CheckedContinuation<Void, Never>] = []

    private(set) var tapRequestArgs: [ProcessGroup?] = []
    private(set) var micRequestArgs: [InputSelection] = []
    /// К6: `driftCompensation` — журнал этого аргумента по каждому вызову отдельно от прочих
    /// (план MEE-315), чтобы тест мог утверждать «`true` в каждом из N вызовов», не только факт
    /// самого вызова. Структура, не тройной тег — `large_tuple` (SwiftLint, порог по умолчанию —
    /// 3 члена уже ошибка), тот же довод, что уже привёл `resolveInputDevice`/`listeners` к
    /// структуре в этом же модуле.
    struct AggregateBuildArgs {
        let tap: TapHandle?
        let microphone: MicrophoneHandle?
        let driftCompensation: Bool
    }
    private(set) var aggregateBuildArgs: [AggregateBuildArgs] = []
    private(set) var releasedTaps: [TapHandle] = []
    private(set) var releasedMicrophones: [MicrophoneHandle] = []
    private(set) var teardownCount = 0

    var aggregateBuildError: Error?
    private var capturedByTap: [UUID: [CaptureProcessDescriptor]] = [:]
    private var eventHandlers: [UUID: (HardwareEvent) -> Void] = [:]
    private var currentOnBuffer: (@Sendable (HardwareBuffer) -> Void)?

    var tapRequestCount: Int { lock.lock(); defer { lock.unlock() }; return tapRequestArgs.count }
    var aggregateBuildCount: Int { lock.lock(); defer { lock.unlock() }; return aggregateBuildArgs.count }

    // MARK: - Управление правом

    /// Хэндл последнего `resolveTap(with: .created(_:))` — тестам, которым нужно продолжить
    /// разговор со швом про КОНКРЕТНЫЙ tap сеанса (К12: `capturedProcesses(_:)` по его токену).
    private(set) var lastCreatedTap: TapHandle?

    func resolveTap(with result: TapAttempt) {
        lock.lock()
        let pending = tapContinuations
        tapContinuations = []
        if case .created(let handle) = result { lastCreatedTap = handle }
        lock.unlock()
        for continuation in pending { continuation.resume(returning: result) }
    }

    func resolveMicrophone(with result: MicrophoneAttempt) {
        lock.lock()
        let pending = micContinuations
        micContinuations = []
        lock.unlock()
        for continuation in pending { continuation.resume(returning: result) }
    }

    /// Ждёт момента, когда `requestSystemAudioTap` реально вызван и continuation
    /// зарегистрирован — сигнал «право tap запрошено», не оценка времени.
    func awaitTapRequested() async {
        lock.lock()
        if !tapContinuations.isEmpty { lock.unlock(); return }
        await withCheckedContinuation { continuation in
            tapRequestedContinuations.append(continuation)
            lock.unlock()
        }
    }

    /// Тот же gate для `requestMicrophone`.
    func awaitMicrophoneRequested() async {
        lock.lock()
        if !micContinuations.isEmpty { lock.unlock(); return }
        await withCheckedContinuation { continuation in
            micRequestedContinuations.append(continuation)
            lock.unlock()
        }
    }

    func requestSystemAudioTap(for group: ProcessGroup?) async -> TapAttempt {
        lock.lock(); tapRequestArgs.append(group); lock.unlock()
        return await withCheckedContinuation { continuation in
            lock.lock()
            tapContinuations.append(continuation)
            let waiters = tapRequestedContinuations
            tapRequestedContinuations = []
            lock.unlock()
            for waiter in waiters { waiter.resume() }
        }
    }

    func requestMicrophone(_ selection: InputSelection) async -> MicrophoneAttempt {
        lock.lock(); micRequestArgs.append(selection); lock.unlock()
        return await withCheckedContinuation { continuation in
            lock.lock()
            micContinuations.append(continuation)
            let waiters = micRequestedContinuations
            micRequestedContinuations = []
            lock.unlock()
            for waiter in waiters { waiter.resume() }
        }
    }

    func releaseTap(_ handle: TapHandle) {
        lock.lock()
        releasedTaps.append(handle)
        let waiters = tapReleasedContinuations
        tapReleasedContinuations = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func releaseMicrophone(_ handle: MicrophoneHandle) {
        lock.lock()
        releasedMicrophones.append(handle)
        let waiters = micReleasedContinuations
        micReleasedContinuations = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Ждёт момента, когда `releaseTap` реально вызван — К17, поздний путь.
    func awaitTapReleased() async {
        lock.lock()
        if !releasedTaps.isEmpty { lock.unlock(); return }
        await withCheckedContinuation { continuation in
            tapReleasedContinuations.append(continuation)
            lock.unlock()
        }
    }

    /// Тот же gate для `releaseMicrophone`.
    func awaitMicrophoneReleased() async {
        lock.lock()
        if !releasedMicrophones.isEmpty { lock.unlock(); return }
        await withCheckedContinuation { continuation in
            micReleasedContinuations.append(continuation)
            lock.unlock()
        }
    }

    // MARK: - Aggregate

    func buildAggregate(
        tap: TapHandle?, microphone: MicrophoneHandle?, driftCompensation: Bool,
        onBuffer: @escaping @Sendable (HardwareBuffer) -> Void
    ) throws -> AggregateHandle {
        lock.lock()
        aggregateBuildArgs.append(AggregateBuildArgs(tap: tap, microphone: microphone,
                                                      driftCompensation: driftCompensation))
        let error = aggregateBuildError
        lock.unlock()
        if let error { throw error }
        lock.lock(); currentOnBuffer = onBuffer; lock.unlock()
        return AggregateHandle()
    }

    func teardownAggregate(_ handle: AggregateHandle) {
        lock.lock(); teardownCount += 1; currentOnBuffer = nil; lock.unlock()
    }

    /// Подаёт буфер текущей сборке — «поток PCM заданной длины/частоты/каналов» шва.
    func feed(_ buffer: HardwareBuffer) {
        lock.lock(); let onBuffer = currentOnBuffer; lock.unlock()
        onBuffer?(buffer)
    }

    // MARK: - Состав захвата

    func setCapturedProcesses(_ processes: [CaptureProcessDescriptor], for tap: TapHandle) {
        lock.lock(); capturedByTap[tap.token] = processes; lock.unlock()
    }

    func capturedProcesses(_ tap: TapHandle) -> [CaptureProcessDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return capturedByTap[tap.token] ?? []
    }

    // MARK: - События

    func subscribeEvents(_ handler: @escaping @Sendable (HardwareEvent) -> Void) -> HardwareSubscription {
        let id = UUID()
        lock.lock(); eventHandlers[id] = handler; lock.unlock()
        return FakeSubscription(id: id, owner: self)
    }

    func emit(_ event: HardwareEvent) {
        lock.lock(); let handlers = Array(eventHandlers.values); lock.unlock()
        for handler in handlers { handler(event) }
    }

    fileprivate func cancelSubscription(_ id: UUID) {
        lock.lock(); eventHandlers.removeValue(forKey: id); lock.unlock()
    }

    private final class FakeSubscription: HardwareSubscription {
        let id: UUID
        weak var owner: FakeHardwareGateway?
        init(id: UUID, owner: FakeHardwareGateway) { self.id = id; self.owner = owner }
        func cancel() { owner?.cancelSubscription(id) }
    }
}

// MARK: - Предел ожидания

final class ManualDeadline: PromptDeadline, @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    /// Аргументы всех вызовов `wait(seconds:)` по порядку — К15/К16 возврата части 1: реализация
    /// с ошибочным пределом (не 45 с) без записи аргумента прошла бы тесты неотличимо.
    private var recordedWaits: [Int] = []
    var waitedSeconds: [Int] { lock.lock(); defer { lock.unlock() }; return recordedWaits }

    /// Заставляет текущий и все следующие вызовы `wait` вернуться немедленно — виртуальное
    /// время шва, план MEE-315: критерий К15/К16 не ждёт настоящие 45 секунд.
    func expireNow() {
        lock.lock()
        expired = true
        let pending = continuations
        continuations = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait(seconds: Int) async {
        lock.lock()
        recordedWaits.append(seconds)
        if expired { lock.unlock(); return }
        lock.unlock()
        await withCheckedContinuation { continuation in
            lock.lock()
            if expired { lock.unlock(); continuation.resume(); return }
            continuations.append(continuation)
            lock.unlock()
        }
    }
}

// MARK: - Драйвер опроса

final class ManualPollDriver: CapturePollDriver, @unchecked Sendable {
    private final class Handle: CapturePollDriverHandle {
        let onStop: () -> Void
        init(_ onStop: @escaping () -> Void) { self.onStop = onStop }
        func stop() { onStop() }
    }

    private let lock = NSLock()
    private var tick: (@Sendable () -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastInterval: Int?

    func start(seconds: Int, tick: @escaping @Sendable () -> Void) -> CapturePollDriverHandle {
        lock.lock()
        startCount += 1
        lastInterval = seconds
        self.tick = tick
        lock.unlock()
        return Handle { [weak self] in
            self?.lock.lock(); self?.stopCount += 1; self?.tick = nil; self?.lock.unlock()
        }
    }

    func fire() {
        lock.lock(); let current = tick; lock.unlock()
        current?()
    }
}

// MARK: - Харнесс

struct Harness {
    let gateway = FakeHardwareGateway()
    let deadline = ManualDeadline()
    let poll = ManualPollDriver()
    let power = FakePowerPort(snapshot: PowerSnapshot(
        source: .ac, batteryFraction: nil, isLowPowerModeEnabled: false,
        thermalPressure: .nominal, checkedAt: Date()
    ))
    let port: AudioCaptureImpl

    init() {
        port = AudioCaptureImpl(power: power, gateway: gateway, deadline: deadline, pollDriver: poll)
    }

    /// `directory` обязан существовать — как и в проде, его создаёт `storage` до вызова `start`.
    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func request(
        directory: URL,
        group: ProcessGroup? = ProcessGroup(appKey: "bundle:us.zoom.xos", pids: [111], observedAt: Date()),
        input: InputSelection = .systemDefault,
        systemFormat: TrackFormat = TrackFormat(sampleRate: 48_000, channelCount: 2),
        micFormat: TrackFormat = TrackFormat(sampleRate: 48_000, channelCount: 1)
    ) -> CaptureRequest {
        CaptureRequest(recordingId: UUID(), meetingId: nil, directory: directory, group: group,
                       input: input, systemFormat: systemFormat, micFormat: micFormat)
    }
}

extension HardwareBuffer {
    static func samples(
        _ slot: Slot, frameCount: Int, channelCount: Int, hostTime: UInt64, value: Float = 0.1
    ) -> HardwareBuffer {
        HardwareBuffer(slot: slot, samples: [Float](repeating: value, count: frameCount * channelCount),
                       frameCount: frameCount, channelCount: channelCount, hostTime: hostTime)
    }
}

// MARK: - Исходники модуля (К8, К19 — способ Г/механически, план MEE-315)

struct SourceFile {
    let name: String
    let text: String
}

enum CaptureSources {
    static func directory(_ relative: String, from file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    static func swiftFiles(in relative: String) throws -> [SourceFile] {
        let root = directory(relative)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { name in
            SourceFile(name: name, text: try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8))
        }
    }

    static func sources() throws -> [SourceFile] { try swiftFiles(in: "Sources/Capture") }
}
