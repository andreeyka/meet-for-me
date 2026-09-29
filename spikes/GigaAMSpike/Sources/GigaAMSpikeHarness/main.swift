//  GigaAMSpikeHarness
//
//  Спайк R12 (docs/architecture.md) · Владелец задачи: Архитектор (MEE-426) · Слой: спайк
//
//  Каталог — код спайка, а не модуль (docs/module-map.md: «Спайки не принадлежат модулям»):
//  отдельный пакет spikes/GigaAMSpike/, не таргет Packages/Mac — sherpa-onnx тянет ~168 МиБ
//  бинарников, и эта цена не должна ложиться на каждую сборку общего пакета и на каждый
//  прогон CI (возврат РП, MEE-426, приёмка #158). CI этот пакет не собирает (spikes/README.md
//  — «CI спайки не собирает», тот же приём, что уже принят для spikes/capture-cli). Результат
//  спайка — измерения комментарием в MEE-426, не код, переезжающий в модуль `gigaam`
//  (Packages/Core/Sources/GigaAM/, владелец DEV-2) без отдельной задачи с контрактом (тот же
//  файл module-map.md).
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
//  §2 — источник модели и довод, почему это тот же класс формата). Размерность мел-признаков —
//  64, явно (не значение по умолчанию 80 из примеров sherpa-onnx для Whisper/Paraformer):
//  подтверждено приёмкой РП (MEE-426, #158) — верное значение стоит за метаданными
//  `is_giga_am=1` экспорта, которые без реальной загрузки в этой сессии проверить нельзя было.
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
      [--chunk-seconds N] [--timestamps 1]
      --model  файл энкодера CTC (`gigaam_v3_e2e_ctc_int8.onnx` — точное имя и источник
               называет записка MEE-426, §2, и приёмка РП).
      --tokens файл словаря токенов, тем же экспортом.
      --wav    16 кГц, моно, PCM — отказ с точным несовпадением на любом другом формате.
      --threads число потоков ONNX Runtime, целое число (по умолчанию 4).
      --chunk-seconds  резать запись на куски по N с (жёстко, без VAD) и расшифровывать
               их одним распознавателем в одном процессе; 0 или без флага — весь файл
               одним куском. GigaAM v3 e2e_ctc не принимает кусок длиннее ~200 с.
      --timestamps 1   напечатать метки времени токенов первого куска (токен@с).

  Печатает: распознанный текст, RTF (время расшифровки / длительность записи),
  пиковую резидентную память процесса (МБ), время загрузки модели (с).
"""

let rawArguments = Array(CommandLine.arguments.dropFirst())
guard rawArguments.first == "run" else { fail(usage) }
private let arguments = Arguments(Array(rawArguments.dropFirst()))

guard let modelPath = arguments["model"] else { fail("--model обязателен\n\n" + usage) }
guard let tokensPath = arguments["tokens"] else { fail("--tokens обязателен\n\n" + usage) }
guard let wavPath = arguments["wav"] else { fail("--wav обязателен\n\n" + usage) }

// Нечисловое значение — явная ошибка, не молчаливый откат к 4: спайк меряет производительность,
// и тихая подмена аргумента, который читатель измерений посчитал заданным, исказила бы RTF
// без единого следа в выводе.
let threadCount: Int
if let rawThreads = arguments["threads"] {
    guard let parsed = Int(rawThreads) else {
        fail("--threads: '\(rawThreads)' не целое число")
    }
    threadCount = parsed
} else {
    threadCount = 4
}

// Кусок длиннее ~200 с энкодер не примет вовсе: позиционное кодирование экспорта рассчитано
// на 5000 кадров по 40 мс, дальше ONNX Runtime падает на broadcast в self_attn (замер R12,
// MEE-426, 29.09). Память на куске растёт квадратично (внимание), поэтому запись длиннее
// минуты стенду нужно подавать кусками — как её и подаст реальный движок.
let chunkSeconds: Double
if let rawChunk = arguments["chunk-seconds"] {
    guard let parsed = Double(rawChunk), parsed >= 0 else {
        fail("--chunk-seconds: '\(rawChunk)' не неотрицательное число")
    }
    chunkSeconds = parsed
} else {
    chunkSeconds = 0
}
let printTimestamps = arguments["timestamps"] == "1"

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
let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 64)
var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: modelConfig)
let recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)
let loadSeconds = Date().timeIntervalSince(loadStart)

let samples = loadMono16kSamples(wavPath: wavPath)
let audioSeconds = Double(samples.count) / 16_000.0

let chunkSize = chunkSeconds > 0 ? max(Int(chunkSeconds * 16_000), 1) : max(samples.count, 1)

/// Метки CTC — кадр, на котором модель выдала токен (шаг 40 мс), а не границы слова.
private func timestampsLine(_ result: SherpaOnnxOfflineRecognitionResult) -> String {
    let raw = result.result.pointee
    guard let tokens = raw.tokens_arr, let stamps = raw.timestamps else {
        return "метки: модель их не выдала"
    }
    var line = "метки (токен@с):"
    for index in 0..<Int(raw.count) {
        let token = tokens[index].map { String(cString: $0) } ?? "?"
        line += String(format: " %@@%.2f", token, stamps[index])
    }
    return line
}

var texts: [String] = []
var worstChunkSeconds = 0.0
let inferenceStart = Date()
var offset = 0
while offset < samples.count {
    let end = min(offset + chunkSize, samples.count)
    let chunkStart = Date()
    let result = recognizer.decode(samples: Array(samples[offset..<end]), sampleRate: 16_000)
    worstChunkSeconds = max(worstChunkSeconds, Date().timeIntervalSince(chunkStart))
    texts.append(result.text)
    if texts.count == 1 {
        if printTimestamps { print(timestampsLine(result)) }
        // Сравнение с итоговым пиком показывает, копится ли память от куска к куску.
        print(String(format: "пиковая память после 1-го куска: %.1f МБ",
                     Double(peakResidentMemoryBytes()) / 1_048_576.0))
    }
    offset = end
}
let inferenceSeconds = Date().timeIntervalSince(inferenceStart)

let rtf = audioSeconds > 0 ? inferenceSeconds / audioSeconds : .nan
let peakMB = Double(peakResidentMemoryBytes()) / 1_048_576.0

if texts.count == 1 {
    print("текст: \(texts[0])")
} else {
    // Час речи — десятки тысяч символов: печатаются начало и последний кусок, не всё.
    let fullText = texts.joined(separator: " ")
    print("текст (\(fullText.count) симв., кусков \(texts.count)), начало: \(fullText.prefix(400))")
    print("последний кусок: \(texts.last ?? "")")
}
print(String(format: "RTF: %.3f (расшифровка %.2f с на %.2f с звука; худший кусок %.2f с)",
             rtf, inferenceSeconds, audioSeconds, worstChunkSeconds))
print(String(format: "пиковая память: %.1f МБ", peakMB))
print(String(format: "время загрузки модели: %.2f с", loadSeconds))
