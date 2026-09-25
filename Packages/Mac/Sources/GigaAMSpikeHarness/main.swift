//  GigaAMSpikeHarness
//
//  Спайк R12 (docs/architecture.md) · Владелец задачи: Архитектор (MEE-426) · Слой: спайк
//
//  Каталог — код спайка, а не модуль (docs/module-map.md: «Спайки не принадлежат модулям»):
//  живёт в Packages/Mac, а не в spikes/, только потому что spikes/ не собирает CI
//  (spikes/README.md: «CI спайки не собирает»), а этому спайку нужна проверка сборки на
//  macos-14 (готовность MEE-426). Результат спайка — измерения комментарием в MEE-426, не
//  код, переезжающий в модуль `gigaam` (Packages/Core/Sources/GigaAM/, владелец DEV-2) без
//  отдельной задачи с контрактом (тот же файл module-map.md).
//
//  Назначение — R12: реальная скорость (RTF), пиковая память и время загрузки GigaAM v3
//  `e2e_ctc` на Apple Silicon через sherpa-onnx (C API — решение Q10 architecture.md,
//  подтверждено запиской MEE-426). Рантайм — официальный SwiftPM-пакет k2-fsa/sherpa-onnx,
//  зафиксирован точной версией 1.13.8 (Package.swift), не диапазоном: спайк — не место для
//  сюрприза от подхваченного новее бинарника без предупреждения.
//
//  Формат модели GigaAM `e2e_ctc` — одноэнкодерный CTC-граф в стиле NeMo (не transducer,
//  не whisper): конфигурация `nemo_ctc`/`modelType: "nemo_ctc"`, тот же путь, которым
//  sherpa-onnx уже поддерживает произвольные экспорты NeMo-CTC-моделей (записка MEE-426,
//  §2 — источник модели и довод, почему это тот же класс формата).
//
//  Модель и WAV — аргументами командной строки; ни то, ни другое в репозиторий не кладётся.
//  Точки вызова sherpa-onnx списаны с `swift-api-examples/decode-file-non-streaming.swift`
//  самого пакета (ветка исключена из собираемых источников таргета `SherpaOnnx` его же
//  `Package.swift` — это пример, а не библиотека, — но публичный API, который она
//  показывает, тот же, что собирает `import SherpaOnnx`).
//
//  Прогон — на физическом Mac РП; эта сессия Swift не собирает и не запускает ничего сама
//  (нет тулчейна) — API sherpa-onnx сверен чтением `SherpaOnnx.swift` и примера пакета на
//  зафиксированном тэге `v1.13.8` (raw.githubusercontent.com), не по памяти.

import AVFoundation
import Foundation
import SherpaOnnx

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
GigaAMSpikeHarness — спайк R12 (docs/architecture.md): GigaAM v3 e2e_ctc на Apple Silicon
через sherpa-onnx (NeMo-CTC).

  run --model PATH-К-ONNX --tokens PATH-К-TOKENS.TXT --wav PATH [--threads 4]
      --model  файл энкодера CTC (например, `gigaam_v3_e2e_ctc.onnx` — точное имя
               и источник называет записка MEE-426, §2).
      --tokens файл словаря токенов, тем же экспортом.
      --wav    16 кГц, моно, PCM — отказ с точным несовпадением на любом другом формате.
      --threads число потоков ONNX Runtime (по умолчанию 4).

  Печатает: распознанный текст, RTF (время расшифровки / длительность записи),
  пиковую резидентную память процесса (МБ), время загрузки модели (с).
"""

let rawArguments = Array(CommandLine.arguments.dropFirst())
guard rawArguments.first == "run" else { fail(usage) }
private let arguments = Arguments(Array(rawArguments.dropFirst()))

guard let modelPath = arguments["model"] else { fail("--model обязателен\n\n" + usage) }
guard let tokensPath = arguments["tokens"] else { fail("--tokens обязателен\n\n" + usage) }
guard let wavPath = arguments["wav"] else { fail("--wav обязателен\n\n" + usage) }
let threadCount = Int(arguments["threads"] ?? "") ?? 4

// MARK: - Загрузка WAV: 16 кГц, моно — точное несовпадение обязано отказать, не подгонять

/// GigaAM обучен на 16 кГц моно — посылка входа неверна на любом другом формате, и
/// молчаливый ресемплинг здесь скрыл бы это от читателя измерений R12: RTF и точность на
/// ресемплированном звуке — не то же самое измерение, что на нативном частотном плане.
private func loadMono16kSamples(wavPath: String) -> [Float] {
    let url = URL(fileURLWithPath: wavPath)
    guard let audioFile = try? AVAudioFile(forReading: url) else {
        fail("--wav: не удалось открыть \(wavPath)")
    }
    let format = audioFile.processingFormat
    guard format.sampleRate == 16_000 else {
        fail("--wav: частота дискретизации \(Int(format.sampleRate)) Гц, нужна 16000 — "
             + "пересэмплируйте до подачи в стенд (не задача спайка тихо это чинить)")
    }
    guard format.channelCount == 1 else {
        fail("--wav: \(format.channelCount) канал(ов), нужен 1 (моно)")
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
        fail("--wav: не удалось выделить буфер на \(audioFile.length) фреймов")
    }
    guard (try? audioFile.read(into: buffer)) != nil else {
        fail("--wav: не удалось прочитать содержимое \(wavPath)")
    }
    guard let channelData = buffer.floatChannelData else {
        fail("--wav: формат буфера не даёт float-каналы (нестандартный PCM)")
    }
    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
}

// MARK: - Измерение пиковой резидентной памяти процесса

/// `mach_task_basic_info.resident_size_max` — тот же приём, что использует Activity Monitor
/// для «Memory» процесса; меряется ПОСЛЕ расшифровки, а не ДО — иначе пик, случившийся во
/// время инференса (обычно самый тяжёлый момент), был бы не виден.
private func peakResidentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return info.resident_size_max
}

// MARK: - Точка входа

let loadStart = Date()
let nemoCtcConfig = sherpaOnnxOfflineNemoEncDecCtcModelConfig(model: modelPath)
let modelConfig = sherpaOnnxOfflineModelConfig(
    tokens: tokensPath,
    nemoCtc: nemoCtcConfig,
    numThreads: threadCount,
    provider: "cpu",
    modelType: "nemo_ctc"
)
let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: modelConfig)
let recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)
let loadSeconds = Date().timeIntervalSince(loadStart)

let samples = loadMono16kSamples(wavPath: wavPath)
let audioSeconds = Double(samples.count) / 16_000.0

let inferenceStart = Date()
let result = recognizer.decode(samples: samples, sampleRate: 16_000)
let inferenceSeconds = Date().timeIntervalSince(inferenceStart)

let rtf = audioSeconds > 0 ? inferenceSeconds / audioSeconds : .nan
let peakMB = Double(peakResidentMemoryBytes()) / 1_048_576.0

print("текст: \(result.text)")
print(String(format: "RTF: %.3f (расшифровка %.2f с на %.2f с звука)", rtf, inferenceSeconds, audioSeconds))
print(String(format: "пиковая память: %.1f МБ", peakMB))
print(String(format: "время загрузки модели: %.2f с", loadSeconds))
