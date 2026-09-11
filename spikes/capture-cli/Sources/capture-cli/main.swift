import AVFoundation
import CoreAudio
import Foundation

let usage = """
capture-cli — спайк MEE-8 (process tap + микрофон в aggregate device)

  processes [--watch S]           процессы-аудиоклиенты HAL; --watch печатает изменения in/out каждые 250 мс
  devices                         аудиоустройства
  tcc                             состояние прав Microphone и AudioCapture (приватный TCCAccessPreflight — только наблюдение)
  record [опции]                  запись: --pid P[,P] | --bundle-prefix ID | --responsible-pid P | --bundle-ids A[,B] (macOS 26)
         --seconds S --label L --root DIR --clock mic|output --writer raw|apple --flush-ms N
         --no-mic --no-follow --retap --rest-tap --nodrift-tap --vp --vp-ducking default|min --process-restore
         --vp-delay S (включить VP через S секунд после начала записи)
  play [--device-uid UID] [--period 2] [--amplitude 0.3] [--file F --schedule 5,50,125 | --delay S] [--seconds S]
  verify DIR [--killed-at-ms MS]  что читается на диске (R9)
  levels DIR [--window S]         уровни по файлам (R1)
  sync DIR [--period 2] [--csv F] расхождение mic/system по чирпам (R2)
  echo DIR --phases far:A-B,near:C-D,double:E-F   voice processing против сырого микрофона в одной записи (R6)
  r6 RAW_DIR VP_DIR               сравнение прогонов scripts/r6-echo.sh (R6)
  channels FILE --interleave N [--from S --to S --window S]   поканальные уровни по сырым байтам
  vp-hold [--seconds S] [--vp-ducking min]                    другой клиент с voice processing на микрофоне
"""

struct Arguments {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        let flagNames: Set<String> = ["no-mic", "no-follow", "retap", "rest-tap", "nodrift-tap", "vp", "process-restore"]
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                if flagNames.contains(name) || index + 1 >= raw.count {
                    flags.insert(name)
                } else {
                    values[name] = raw[index + 1]
                    index += 1
                }
            } else {
                positional.append(token)
            }
            index += 1
        }
    }

    func double(_ name: String) -> Double? { values[name].flatMap(Double.init) }
    func list(_ name: String) -> [String] { values[name]?.split(separator: ",").map(String.init) ?? [] }
}

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
let command = arguments.positional.first ?? "help"

func printProcesses(_ processes: [AudioProcess]) {
    print("obj\tpid\tppid\tresp\tout\tin\tbundleID(HAL)\tbundle(path)\tpath")
    for process in processes.sorted(by: { $0.pid < $1.pid }) {
        print("\(process.object)\t\(process.pid)\t\(process.parentPID)\t\(process.responsiblePID)\t"
              + "\(process.isRunningOutput ? 1 : 0)\t\(process.isRunningInput ? 1 : 0)\t\(process.bundleID ?? "-")\t"
              + "\(ProcessTools.bundleIdentifier(ofPath: process.path) ?? "-")\t\(process.path ?? "-")")
    }
}

switch command {
case "processes":
    printProcesses(AudioProcess.all())
    if let watch = arguments.double("watch") {
        var previous = Dictionary(uniqueKeysWithValues: AudioProcess.all().map { ($0.object, $0) })
        let deadline = Date().addingTimeInterval(watch)
        print("\n--- изменения (время, pid, bundleID, out, in) ---")
        while Date() < deadline {
            usleep(250_000)
            let current = Dictionary(uniqueKeysWithValues: AudioProcess.all().map { ($0.object, $0) })
            let stamp = ManifestJSON.formatDate(Date())
            for (object, process) in current {
                let old = previous[object]
                if old == nil || old!.isRunningOutput != process.isRunningOutput || old!.isRunningInput != process.isRunningInput {
                    print("\(stamp)\t\(old == nil ? "+" : "~")\tpid \(process.pid)\t\(process.bundleID ?? "-")\t"
                          + "out=\(process.isRunningOutput ? 1 : 0)\tin=\(process.isRunningInput ? 1 : 0)\t"
                          + "resp=\(process.responsiblePID)\t\(process.executableName ?? "-")")
                }
            }
            for (object, process) in previous where current[object] == nil {
                print("\(stamp)\t-\tpid \(process.pid)\t\(process.bundleID ?? "-")\t\(process.executableName ?? "-")")
            }
            previous = current
        }
    }

case "devices":
    let defaultInput = HAL.defaultInput(), defaultOutput = HAL.defaultOutput()
    for device in HAL.devices() {
        var info = HAL.describeDevice(device)
        info["defaultInput"] = device == defaultInput
        info["defaultOutput"] = device == defaultOutput
        info["latencyIn"] = HAL.latency(device, scope: kAudioObjectPropertyScopeInput)
        info["latencyOut"] = HAL.latency(device, scope: kAudioObjectPropertyScopeOutput)
        let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }

case "tcc":
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    let preflight = handle.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
    print("bundleId=\(Bundle.main.bundleIdentifier ?? "-") executable=\(CommandLine.arguments[0])")
    print("AVCaptureDevice.authorizationStatus(.audio)=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 authorized)")
    for service in ["kTCCServiceAudioCapture", "kTCCServiceMicrophone", "kTCCServiceScreenCapture"] {
        print("TCCAccessPreflight(\(service))=\(preflight.map { String($0(service as CFString, nil)) } ?? "символ недоступен") (0 granted, 1 denied, 2 unknown)")
    }

case "record":
    let supportRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.andreeyka.meetforme.spike.capture")
    var options = RecordOptions(root: arguments.values["root"].map { URL(fileURLWithPath: $0) } ?? supportRoot)
    options.label = arguments.values["label"] ?? ""
    options.pids = arguments.list("pid").compactMap { pid_t($0) }
    options.bundlePrefix = arguments.values["bundle-prefix"]
    options.responsiblePID = arguments.values["responsible-pid"].flatMap { pid_t($0) }
    options.bundleIDs = arguments.list("bundle-ids")
    options.processRestore = arguments.flags.contains("process-restore")
    options.seconds = arguments.double("seconds")
    options.mic = !arguments.flags.contains("no-mic")
    options.clock = arguments.values["clock"] ?? "mic"
    options.followDefaultInput = !arguments.flags.contains("no-follow")
    options.retap = arguments.flags.contains("retap")
    options.writer = arguments.values["writer"] ?? "raw"
    options.flushMs = arguments.values["flush-ms"].flatMap(Int.init) ?? 200
    options.restTap = arguments.flags.contains("rest-tap")
    options.noDriftTap = arguments.flags.contains("nodrift-tap")
    options.voiceProcessing = arguments.flags.contains("vp")
    options.vpDucking = arguments.values["vp-ducking"] ?? "default"
    options.vpDelay = arguments.double("vp-delay") ?? 0
    let recorder = try Recorder(options: options)
    recorder.run()

case "play":
    let schedule = arguments.list("schedule").compactMap(Double.init)
    try Player().run(deviceUID: arguments.values["device-uid"], period: arguments.double("period") ?? 2,
                     amplitude: Float(arguments.double("amplitude") ?? 0.3), band: arguments.values["band"] ?? "low",
                     file: arguments.values["file"].map { URL(fileURLWithPath: $0) },
                     schedule: schedule.isEmpty ? [arguments.double("delay") ?? 0.5] : schedule,
                     seconds: arguments.double("seconds"))

case "vp-hold":
    // Другой клиент с voice processing на микрофоне — как Chrome/Zoom во время созвона. Ничего не пишет.
    let engine = AVAudioEngine()
    try engine.inputNode.setVoiceProcessingEnabled(true)
    if arguments.values["vp-ducking"] == "min" {
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
    }
    let format = engine.inputNode.outputFormat(forBus: 0)
    engine.inputNode.installTap(onBus: 0, bufferSize: 4800, format: format) { _, _ in }
    engine.prepare()
    try engine.start()
    print("vp-hold pid=\(getpid()) rate=\(format.sampleRate) channels=\(format.channelCount) ducking=\(arguments.values["vp-ducking"] ?? "default") startHostS=\(hostTimeSeconds(nowHost()))")
    DispatchQueue.main.asyncAfter(deadline: .now() + (arguments.double("seconds") ?? 30)) {
        engine.stop()
        print("vp-hold stop hostS=\(hostTimeSeconds(nowHost()))")
        exit(0)
    }
    RunLoop.main.run()

case "r6":
    guard arguments.positional.count > 2 else { print(usage); exit(1) }
    Analysis.compareR6(rawDirectory: URL(fileURLWithPath: arguments.positional[1]),
                       vpDirectory: URL(fileURLWithPath: arguments.positional[2]))

case "channels":
    guard arguments.positional.count > 1 else { print(usage); exit(1) }
    Analysis.channels(file: URL(fileURLWithPath: arguments.positional[1]),
                      interleave: arguments.values["interleave"].flatMap(Int.init) ?? 1,
                      from: arguments.double("from") ?? 0, to: arguments.double("to"),
                      window: arguments.double("window") ?? 5, rate: arguments.double("rate") ?? 48000)

case "verify", "levels", "sync", "echo":
    guard arguments.positional.count > 1 else { print(usage); exit(1) }
    let directory = URL(fileURLWithPath: arguments.positional[1])
    switch command {
    case "verify": Analysis.verify(directory: directory, killedAtMs: arguments.double("killed-at-ms"))
    case "levels": Analysis.levels(directory: directory, window: arguments.double("window") ?? 1)
    case "sync": Analysis.sync(directory: directory, period: arguments.double("period") ?? 2, band: arguments.values["band"] ?? "low",
                               csvPath: arguments.values["csv"])
    default:
        let phases = arguments.list("phases").compactMap { item -> (String, Double, Double)? in
            let parts = item.split(separator: ":")
            let range = parts.last?.split(separator: "-").compactMap { Double($0) } ?? []
            return parts.count == 2 && range.count == 2 ? (String(parts[0]), range[0], range[1]) : nil
        }
        Analysis.echo(directory: directory, phases: phases)
    }

default:
    print(usage)
}
