//  CaptureManualHarness
//
//  Модуль: capture · Владелец: DEV-1 · Слой: тестовое средство модуля (исполняемый таргет)
//
//  Каталог принадлежит владельцу модуля capture: файлы здесь изменяет только он (П1).
//  Назначение — план проверки MEE-315, §5 и §6: интерактивный носитель ручных М1/М2
//  (вызов AudioCapturePort.start/stop под своим bundle id) и писатель К27(б)
//  (тот же путь записи трека и манифеста, что у реализации, на синтетическом PCM).
//
//  Два режима — один процесс:
//    start   интерактивный носитель М1/М2 (§5): реальный AudioCaptureImpl, печатает исход
//            start(_:), поток events() построчно, останавливает через фиксированный --seconds.
//    write   писатель К27(б) (§6): пишет трек и manifest.json ТЕМ ЖЕ путём, каким пишет
//            реализация (package-видимые TrackFile/ManifestWriter в Capture), без CoreAudio
//            и без TCC — только синтетические байты. Тест убивает процесс SIGKILL в контро-
//            лируемый момент и проверяет диск/recover() отдельно.

import Capture
import DomainCore
import Foundation

// MARK: - Минимальный PowerPort носителя

// Харнесс не тянет Permissions (реализация PowerPort) и не тянет DomainTestKit
// (Package.swift этого таргета — только Capture + DomainCore, вне зоны этой задачи менять) —
// собственная тривиальная реализация протокола ровно для того, чтобы AudioCaptureImpl(power:)
// было чем собрать; удержание системы М1/М2 не проверяют.
private final class HarnessPowerToken: PowerActivityToken, @unchecked Sendable {
    let reason: PowerActivityReason
    let label: String
    init(reason: PowerActivityReason, label: String) {
        self.reason = reason
        self.label = label
    }
    func end() {}
}

private final class HarnessPowerPort: PowerPort, @unchecked Sendable {
    func snapshot() async -> PowerSnapshot {
        PowerSnapshot(source: .ac, batteryFraction: nil, isLowPowerModeEnabled: false,
                      thermalPressure: .nominal, checkedAt: Date())
    }
    func events() -> AsyncStream<PowerEvent> { AsyncStream { _ in } }
    func beginActivity(reason: PowerActivityReason, label: String) async -> PowerActivityToken {
        HarnessPowerToken(reason: reason, label: label)
    }
}

// MARK: - Разбор аргументов

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private struct Arguments {
    var values: [String: String] = [:]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--"), index + 1 < raw.count {
                values[String(token.dropFirst(2))] = raw[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
    }

    subscript(_ key: String) -> String? { values[key] }
}

private let usage = """
CaptureManualHarness — носитель М1/М2 и писатель К27(б) (план MEE-315 §5, §6).

  start --directory DIR [--seconds 30] [--group-app-key KEY --group-pid PID[,PID...]]
        [--input none|default|UID]
        Интерактивный носитель: вызывает start(_:), печатает исход и events() построчно,
        останавливает через --seconds (не stdin — `open -n -W` его не подключает).
        group-app-key отсутствует → group: nil.

  write --directory DIR --channel mic|system [--sample-rate 48000] [--channel-count 1]
        [--chunk-frames 480] [--chunk-interval-ms 20]
        Писатель: открывает трек и manifest.json тем же путём, что и реализация, дописывает
        синтетический PCM порциями до получения SIGKILL. Не финализирует ничего — сам процесс
        не завершается штатно (тест обязан его убить).
"""

let rawArguments = Array(CommandLine.arguments.dropFirst())
guard let mode = rawArguments.first else { fail(usage) }
let arguments = Arguments(Array(rawArguments.dropFirst()))

switch mode {
case "start":
    await runInteractive(arguments)
case "write":
    runWriter(arguments)
default:
    fail(usage)
}

// MARK: - Режим start (М1/М2)

private func parseInput(_ raw: String?) -> InputSelection {
    switch raw {
    case nil, "default": return .systemDefault
    case "none": return .none
    case let uid?: return .uid(uid)
    }
}

private func buildRequest(_ arguments: Arguments, directory: URL) -> CaptureRequest {
    let group: ProcessGroup? = arguments["group-app-key"].map { appKey in
        let pids = (arguments["group-pid"] ?? "")
            .split(separator: ",")
            .compactMap { Int32($0) }
        return ProcessGroup(appKey: appKey, pids: pids, observedAt: Date())
    }
    let input = parseInput(arguments["input"])
    return CaptureRequest(
        recordingId: UUID(), meetingId: nil, directory: directory, group: group, input: input,
        systemFormat: TrackFormat(sampleRate: 48_000, channelCount: 2),
        micFormat: TrackFormat(sampleRate: 48_000, channelCount: 1)
    )
}

private func runInteractive(_ arguments: Arguments) async {
    guard let directoryPath = arguments["directory"] else { fail("--directory обязателен") }
    let directory = URL(fileURLWithPath: directoryPath)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let request = buildRequest(arguments, directory: directory)
    let port = AudioCaptureImpl(power: HarnessPowerPort())
    let eventsTask = Task {
        for await event in port.events() {
            print("event: \(event)")
            fflush(stdout)
        }
    }

    do {
        let started = try await port.start(request)
        print("start: ok \(started)")
    } catch {
        print("start: throw \(error)")
    }
    fflush(stdout)

    // Не readLine(): `open -n -W` (§6 плана — тот же способ, каким TCC относит промпт к bundle id
    // харнесса, не к терминалу) не подключает stdin запущенного .app к интерактивному терминалу.
    // Тот же приём, что и у spikes/capture-cli — фиксированная длительность, не ожидание ввода.
    let seconds = Double(arguments["seconds"] ?? "") ?? 30
    print("--- запись \(Int(seconds)) с, затем остановка ---")
    fflush(stdout)
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

    do {
        let manifest = try await port.stop()
        print("stop: ok \(manifest)")
    } catch {
        print("stop: throw \(error)")
    }
    fflush(stdout)
    eventsTask.cancel()
}

// MARK: - Режим write (К27б)

private func writeInitialManifest(channel: RecordingManifest.Channel, track: TrackFile,
                                  sampleRate: Int, channelCount: Int, directory: URL) {
    // manifest.json — атомарно, тем же ManifestWriter, что и реализация; не финализирован,
    // endedAt: nil, ровно тот вид, в котором его застал бы SIGKILL посреди сеанса.
    do {
        let recordingId = UUID()
        let trackDescriptor = try RecordingManifest.Track(
            channel: channel, fileName: track.fileName, sampleRate: sampleRate,
            channelCount: channelCount, format: "pcm-caf"
        )
        let manifest = try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: Date(), endedAt: nil, tracks: [trackDescriptor], markers: [],
            capturedProcesses: [], captureGroupKey: nil, inputDevices: [], discontinuities: [],
            isFinalized: false
        )
        try ManifestWriter.writeAtomically(manifest, to: directory)
    } catch {
        fail("не удалось записать manifest.json: \(error)")
    }
}

/// Дописывает синтетический PCM порциями до SIGKILL — тест решает, когда убить процесс,
/// по числу строк "wrote", прочитанных из stdout (каждая — после fsync очередного чанка).
private func writeChunksForever(
    track: TrackFile, chunkFrames: Int, channelCount: Int, chunkIntervalMs: UInt64
) -> Never {
    var totalFrames = 0
    while true {
        let samples = [Float](repeating: 0.1, count: chunkFrames * channelCount)
        do {
            try track.append(samples)
        } catch {
            fail("не удалось дописать трек: \(error)")
        }
        totalFrames += chunkFrames
        track.flush(atHostTime: UInt64(Date().timeIntervalSince1970 * 1000))
        print("wrote: \(totalFrames)")
        fflush(stdout)
        Thread.sleep(forTimeInterval: Double(chunkIntervalMs) / 1000)
    }
}

private func runWriter(_ arguments: Arguments) {
    guard let directoryPath = arguments["directory"] else { fail("--directory обязателен") }
    guard let channelArg = arguments["channel"], let channel = RecordingManifest.Channel(rawValue: channelArg) else {
        fail("--channel mic|system обязателен")
    }
    let sampleRate = Int(arguments["sample-rate"] ?? "") ?? 48_000
    let channelCount = Int(arguments["channel-count"] ?? "") ?? 1
    let chunkFrames = Int(arguments["chunk-frames"] ?? "") ?? 480
    let chunkIntervalMs = UInt64(arguments["chunk-interval-ms"] ?? "") ?? 20

    let directory = URL(fileURLWithPath: directoryPath)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let format = TrackFormat(sampleRate: sampleRate, channelCount: channelCount)
    let track: TrackFile
    do {
        track = try TrackFile(directory: directory, channel: channel, format: format)
    } catch {
        fail("не удалось открыть трек: \(error)")
    }

    writeInitialManifest(channel: channel, track: track, sampleRate: sampleRate,
                         channelCount: channelCount, directory: directory)

    print("writer: ready \(track.fileName)")
    fflush(stdout)

    writeChunksForever(track: track, chunkFrames: chunkFrames, channelCount: channelCount,
                       chunkIntervalMs: chunkIntervalMs)
}
