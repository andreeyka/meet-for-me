//  GigaAMXPCHarness — стенд Z6 (MEE-504): настоящий `TranscriptionEngine.xpc` через `EngineXPCClient`.
//
//  Хост — `.app`, в `Contents/XPCServices/` которого лежит собранный `TranscriptionEngine.xpc`
//  (scripts/build.sh): `NSXPCConnection(serviceName:)` ищет сервис в бандле вызывающего процесса.
//  Запись — `AnyIdFinalizedRecordingRepository` (дорожки `audio-system.caf` стерео и
//  `audio-mic.caf` моно, `pcm-caf` 48 кГц); файлы кладутся ссылками во временный `FileLayout`.
//  Каталог моделей — `StandCatalog`: профиль `ru-default` с одной ASR-моделью в заданном каталоге.
//
//  Режимы:
//    transcribe --model DIR --system CAF [--mic CAF] --out JSON [--cancel-at 0.5]
//    download --root DIR --out JSON [--pause-at 0.5]      (Z7 п. 6, MEE-452)

import Darwin
import DomainCore
import DomainTestKit
import EngineXPCClient
import Foundation

let serviceName = "com.andreeyka.meetforme.TranscriptionEngine"
let profileId = "ru-default"

enum StandError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self {
        case .usage(let text): return text
        }
    }
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func now() -> Double { Date().timeIntervalSince1970 }

func writeJSON(_ object: [String: Any], to path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - Процесс сервиса

/// PID процесса сервиса: самый новый процесс с именем `TranscriptionEngine` этого пользователя.
func servicePID() -> pid_t? {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-n", "-x", "TranscriptionEngine"]
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

struct Usage {
    var residentBytes: UInt64
    var footprintBytes: UInt64
    var lifetimeMaxFootprintBytes: UInt64
    var cpuSeconds: Double
}

func usage(of pid: pid_t) -> Usage? {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = Double(info.ri_user_time + info.ri_system_time)
    return Usage(
        residentBytes: info.ri_resident_size, footprintBytes: info.ri_phys_footprint,
        lifetimeMaxFootprintBytes: info.ri_lifetime_max_phys_footprint,
        cpuSeconds: ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
    )
}

/// Опрос памяти процесса сервиса каждые 50 мс: пик RSS и пик footprint.
final class MemoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var peakResident: UInt64 = 0
    private var peakFootprint: UInt64 = 0
    private var running = true
    let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                if let sample = usage(of: pid) {
                    lock.withLock {
                        peakResident = max(peakResident, sample.residentBytes)
                        peakFootprint = max(peakFootprint, sample.footprintBytes)
                    }
                }
                usleep(50_000)
            }
        }
    }

    func stop() -> (resident: UInt64, footprint: UInt64) {
        lock.withLock {
            running = false
            return (peakResident, peakFootprint)
        }
    }
}

// MARK: - Каталог моделей стенда

/// Профиль `ru-default` с одной ASR-моделью в `directory`. Остальное порта стенду не нужно.
final class StandCatalog: ModelCatalogPort, @unchecked Sendable {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func resolve(profileId: String) async throws -> ResolvedProfile {
        ResolvedProfile(
            profileId: profileId, language: "ru",
            asr: ModelBundle(
                modelId: "gigaam-v3-e2e-ctc-int8", version: "3.0.0", role: .asr, runtime: .onnx,
                directoryURL: directory
            ),
            vad: nil, diarization: nil, embedding: nil,
            diarizationParameters: DiarizationParameters(
                expectedSpeakers: nil, clusteringThreshold: 0.7, minSegmentMs: 500
            )
        )
    }
    func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken { ModelUseToken(rawValue: UUID()) }
    func endUse(_ token: ModelUseToken) async {}
    func refreshCatalog() async throws {}
    func models() async -> [ModelDescriptor] { [] }
    func model(id: String, version: String) async -> ModelDescriptor? { nil }
    func state(id: String, version: String) async -> ModelState { .downloaded }
    func download(id: String, version: String) async throws {}
    func cancelDownload(id: String, version: String) async {}
    func verify(id: String, version: String) async throws {}
    func delete(id: String, version: String) async throws {}
    func diskUsage() async -> [ModelDiskUsage] { [] }
    func profiles() async -> [TranscriptionProfile] { [] }
    func saveProfile(_ profile: TranscriptionProfile) async throws {}
    func deleteProfile(id: String) async throws {}
    func missingModels(profileId: String) async throws -> [ModelDescriptor] { [] }
    func events() -> AsyncStream<ModelCatalogEvent> { AsyncStream { $0.finish() } }
}

// MARK: - transcribe

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String: Any]] = []
    private var onFraction: (@Sendable (Double) -> Void)?
    let start: Double

    init(start: Double, onFraction: (@Sendable (Double) -> Void)? = nil) {
        self.start = start
        self.onFraction = onFraction
    }

    func append(_ progress: TranscriptionProgress) {
        let callback = lock.withLock { () -> (@Sendable (Double) -> Void)? in
            entries.append(["t": now() - start, "stage": progress.stage, "fraction": progress.fraction])
            return onFraction
        }
        callback?(progress.fraction)
    }

    var all: [[String: Any]] { lock.withLock { entries } }
}

func runTranscribe(_ arguments: [String]) async throws {
    guard let model = option("--model", in: arguments), let system = option("--system", in: arguments),
          let out = option("--out", in: arguments) else {
        throw StandError.usage("transcribe --model DIR --system CAF [--mic CAF] --out JSON [--cancel-at F]")
    }
    let mic = option("--mic", in: arguments)
    let cancelAt = option("--cancel-at", in: arguments).flatMap(Double.init)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gigaam-xpc-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = FileLayout(root: root)
    let recordingId = UUID()
    let tracks = [try RecordingFixtures.systemTrack()] + (mic == nil ? [] : [try RecordingFixtures.micTrack()])
    let record = try RecordingFixtures.record(recordingId: recordingId, tracks: tracks)
    let directory = layout.recordingDirectory(record.manifest.directoryName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("audio-system.caf"), withDestinationURL: URL(fileURLWithPath: system)
    )
    if let mic {
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("audio-mic.caf"), withDestinationURL: URL(fileURLWithPath: mic)
        )
    }
    let recordings = InMemoryRecordingRepository()
    try await recordings.save(record)

    let client = EngineXPCClient(
        serviceName: serviceName, modelCatalog: StandCatalog(directory: URL(fileURLWithPath: model)),
        recordings: recordings, fileLayout: layout
    )
    var result: [String: Any] = ["mode": "transcribe", "model": model, "system": system, "mic": mic ?? NSNull()]
    let pingStart = now()
    result["serviceVersion"] = try await client.ping()
    result["pingS"] = now() - pingStart
    guard let pid = servicePID() else { throw StandError.usage("процесс TranscriptionEngine не найден") }
    result["servicePID"] = Int(pid)
    result["serviceExecutable"] = executablePath(of: pid)
    let probe = MemoryProbe(pid: pid)

    let spec = TranscriptionJobSpec(
        recordingId: recordingId, profileId: profileId, language: "ru",
        wantWordTimestamps: true, diarizeSystemChannel: false
    )
    let start = now()
    let cancelBox = CancelBox()
    let log = ProgressLog(start: start) { fraction in
        if let cancelAt, fraction >= cancelAt { cancelBox.fire() }
    }
    let job = Task { try await client.transcribe(spec) { log.append($0) } }
    cancelBox.set { job.cancel() }
    // Отзывчивость сервиса во время распознавания (замечание ревью (б)): `ping` каждые 2 с.
    let pinger = Task { () -> [Double] in
        var latencies: [Double] = []
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let sent = now()
            if (try? await client.ping()) != nil { latencies.append(now() - sent) }
        }
        return latencies
    }
    do {
        let transcript = try await job.value
        result["wallS"] = now() - start
        let transcriptData = try DomainJSON.encoder().encode(transcript)
        result["transcript"] = try JSONSerialization.jsonObject(with: transcriptData)
        result["outcome"] = "transcript"
    } catch {
        result["wallS"] = now() - start
        result["outcome"] = "\(error)"
        if cancelAt != nil { result["cancelProbe"] = await cancelProbe(pid: pid, firedAt: cancelBox.firedAt) }
    }
    pinger.cancel()
    let pings = await pinger.value
    result["pingsDuringS"] = pings
    result["pingDuringMaxS"] = pings.max() ?? -1
    let peaks = probe.stop()
    result["peakResidentBytes"] = peaks.resident
    result["peakFootprintBytes"] = peaks.footprint
    if let final = usage(of: pid) {
        result["lifetimeMaxFootprintBytes"] = final.lifetimeMaxFootprintBytes
        result["serviceCPUSeconds"] = final.cpuSeconds
    }
    result["serviceAliveAfter"] = kill(pid, 0) == 0
    result["progress"] = log.all
    result["pingAfterS"] = try? await { let t0 = now(); _ = try await client.ping(); return now() - t0 }()
    result["servicePIDAfter"] = servicePID().map(Int.init) ?? NSNull()
    try writeJSON(result, to: out)
    print(result.filter { !["transcript", "progress"].contains($0.key) })
}

func executablePath(of pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(cString: buffer) : "?"
}

final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var fired = false
    private(set) var firedAt: Double?

    func set(_ action: @escaping () -> Void) {
        let fireNow = lock.withLock { () -> Bool in
            self.action = action
            return fired
        }
        if fireNow { action() }
    }

    func fire() {
        let action = lock.withLock { () -> (() -> Void)? in
            guard !fired else { return nil }
            fired = true
            firedAt = now()
            return self.action
        }
        action?()
    }
}

/// После отмены: тратит ли процесс сервиса CPU дальше (работа движка остановилась или нет).
func cancelProbe(pid: pid_t, firedAt: Double?) async -> [String: Any] {
    var samples: [[String: Any]] = []
    for _ in 0..<8 {
        if let sample = usage(of: pid) {
            samples.append(["t": now() - (firedAt ?? now()), "cpuS": sample.cpuSeconds])
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    return ["cpuAfterCancel": samples]
}

// MARK: - Вход

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "transcribe": try await runTranscribe(Array(arguments.dropFirst()))
    case "download": try await runDownload(Array(arguments.dropFirst()))
    default: throw StandError.usage("режим: transcribe | download")
    }
    exit(0)
} catch {
    FileHandle.standardError.write(Data("ошибка: \(error)\n".utf8))
    exit(1)
}
