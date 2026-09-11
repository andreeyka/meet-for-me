import AVFoundation
import Accelerate
import Foundation

// Офлайн-анализ записей: verify (R9), levels (R1), sync (R2), echo (R6). Числа печатаются в stdout.

struct MonoReader {
    let url: URL
    let file: AVAudioFile
    let rate: Double
    let channels: Int
    let length: Int64

    init(_ url: URL) throws {
        self.url = url
        file = try AVAudioFile(forReading: url)
        rate = file.processingFormat.sampleRate
        channels = Int(file.processingFormat.channelCount)
        length = file.length
    }

    /// Моно-микс участка [start, start+count). За пределами файла — нули.
    func read(from start: Int64, count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: max(0, count))
        let begin = max(0, start)
        let available = min(Int64(count) - (begin - start), length - begin)
        guard available > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(available))
        else { return result }
        file.framePosition = begin
        guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(available))) != nil,
              let data = buffer.floatChannelData else { return result }
        let offset = Int(begin - start)
        let scale = 1 / Float(channels)
        for channel in 0..<channels {
            for frame in 0..<Int(buffer.frameLength) { result[offset + frame] += data[channel][frame] * scale }
        }
        return result
    }

    func readAll() -> [Float] { read(from: 0, count: Int(length)) }
}

func rmsDB(_ samples: ArraySlice<Float>) -> Double {
    guard !samples.isEmpty else { return -200 }
    var rms: Float = 0
    samples.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &rms, vDSP_Length($0.count)) }
    return dBFS(rms)
}

func fmt(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))]
}

/// Наклон МНК y(x).
func slope(_ xs: [Double], _ ys: [Double]) -> Double {
    guard xs.count > 1 else { return .nan }
    let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
    var num = 0.0, den = 0.0
    for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
    return den == 0 ? .nan : num / den
}

enum Analysis {

    // MARK: verify — что лежит на диске (R9)

    static func verify(directory: URL, killedAtMs: Double?) {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var startedAt: Date?
        if let data = try? Data(contentsOf: manifestURL) {
            do {
                let manifest = try ManifestJSON.decode(data)
                startedAt = manifest.startedAt
                print("manifest.json: \(data.count) байт, декодирован; нарушение инвариантов: \(manifest.firstViolation() ?? "нет")")
                print("  startedAt=\(ManifestJSON.formatDate(manifest.startedAt)) endedAt=\(manifest.endedAt.map(ManifestJSON.formatDate) ?? "nil") "
                      + "isFinalized=\(manifest.isFinalized) tracks=\(manifest.tracks.map { "\($0.channel.rawValue):\($0.fileName)@\($0.sampleRate)x\($0.channelCount)" }) "
                      + "markers=\(manifest.markers.count) inputDevices=\(manifest.inputDevices.count) processes=\(manifest.capturedProcesses.count)")
            } catch {
                print("manifest.json: \(data.count) байт, НЕ декодирован: \(error)")
            }
        } else {
            print("manifest.json: отсутствует")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasSuffix(".tmp") } ?? []
        print("временные файлы манифеста: \(leftovers.isEmpty ? "нет" : leftovers.joined(separator: ", "))")

        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".caf") }.sorted()
        for name in files {
            let url = directory.appendingPathComponent(name)
            do {
                let caf = try CAFInspection(url: url)
                let seconds = Double(caf.framesOnDisk) / max(caf.sampleRate, 1)
                var line = "\(name): \(caf.formatID) \(Int(caf.sampleRate)) Гц x\(caf.channels), data.size=\(caf.declaredDataSize), "
                    + "кадров на диске \(caf.framesOnDisk) (\(fmt(seconds, 3)) с), хвост \(caf.trailingBytes) байт, чанки \(caf.chunks)"
                if let reader = try? MonoReader(url) {
                    line += "; AVAudioFile: читается, length=\(reader.length) (\(fmt(Double(reader.length) / reader.rate, 3)) с)"
                    let tail = reader.read(from: max(0, reader.length - Int64(reader.rate)), count: Int(reader.rate))
                    line += ", RMS последней секунды \(fmt(rmsDB(tail[...]))) dBFS"
                } else {
                    line += "; AVAudioFile: НЕ открывается"
                }
                if let killedAtMs, let startedAt {
                    let wallMs = killedAtMs - startedAt.timeIntervalSince1970 * 1000
                    line += "; до kill -9 прошло \(fmt(wallMs / 1000, 3)) с, потеряно \(fmt(wallMs - seconds * 1000, 0)) мс"
                }
                print(line)
            } catch {
                print("\(name): заголовок не разобран: \(error)")
            }
        }
        if let text = try? String(contentsOf: directory.appendingPathComponent("events.log"), encoding: .utf8) {
            let lines = text.split(separator: "\n")
            print("events.log: \(lines.count) строк, последняя: \(lines.last.map(String.init)?.prefix(300) ?? "-")")
        }
    }

    // MARK: levels — где звук (R1)

    static func levels(directory: URL, window: Double) {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".caf") }.sorted()
        let readers = files.compactMap { try? MonoReader(directory.appendingPathComponent($0)) }
        guard !readers.isEmpty else { print("нет CAF"); return }
        let seconds = readers.map { Double($0.length) / $0.rate }.max() ?? 0
        let names = readers.map { $0.url.lastPathComponent }
        print("t,s\t" + names.joined(separator: "\t"))
        var series = [[Double]](repeating: [], count: readers.count)
        var t = 0.0
        while t + window <= seconds + 1e-9 {
            var row = [fmt(t, 1)]
            for (index, reader) in readers.enumerated() {
                let samples = reader.read(from: Int64(t * reader.rate), count: Int(window * reader.rate))
                let level = rmsDB(samples[...])
                series[index].append(level)
                row.append(fmt(level))
            }
            print(row.joined(separator: "\t"))
            t += window
        }
        print("\nитог (окно \(window) с): файл, медиана dBFS, p95 dBFS, доля окон громче -50 dBFS")
        for (index, name) in names.enumerated() {
            let values = series[index]
            let loud = Double(values.filter { $0 > -50 }.count) / Double(max(values.count, 1)) * 100
            print("\(name)\t\(fmt(median(values)))\t\(fmt(percentile(values, 0.95)))\t\(fmt(loud, 0)) %")
        }
    }

    // MARK: channels — поканальные уровни по сырым байтам CAF с явной раскладкой

    /// Читает PCM Float32 из data-чанка напрямую и режет на `interleave` каналов, игнорируя заголовок.
    /// Нужен, когда формат потока сменился посреди файла (заголовок говорит 1 канал, а пишется 3).
    static func channels(file: URL, interleave: Int, from: Double, to: Double?, window: Double, rate: Double) {
        guard let caf = try? CAFInspection(url: file), let handle = try? FileHandle(forReadingFrom: file) else {
            print("не разобран \(file.path)"); return
        }
        defer { try? handle.close() }
        let bytesPerFrame = 4 * interleave
        let startOffset = UInt64(caf.dataOffset) + UInt64(from * rate) * UInt64(bytesPerFrame)
        let windowFrames = Int(window * rate)
        print("окно\t" + (0..<interleave).map { "ch\($0) dBFS" }.joined(separator: "\t"))
        var t = from
        try? handle.seek(toOffset: startOffset)
        while to == nil || t < to! {
            let data = handle.readData(ofLength: windowFrames * bytesPerFrame)
            if data.count < bytesPerFrame { break }
            let frames = data.count / bytesPerFrame
            var row = [fmt(t, 1)]
            data.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Float.self)
                for channel in 0..<interleave {
                    var sum = 0.0
                    for frame in 0..<frames { let v = Double(samples[frame * interleave + channel]); sum += v * v }
                    row.append(fmt(dBFS(Float(sqrt(sum / Double(max(frames, 1)))))))
                }
            }
            print(row.joined(separator: "\t"))
            t += window
        }
    }

    // MARK: sync — расхождение каналов по опорным чирпам (R2)

    static func sync(directory: URL, period: Double, band: String, csvPath: String?) {
        guard let system = try? MonoReader(directory.appendingPathComponent("audio-system.caf")),
              let mic = try? MonoReader(directory.appendingPathComponent("audio-mic.caf")) else {
            print("нужны audio-system.caf и audio-mic.caf"); return
        }
        let noDrift = try? MonoReader(directory.appendingPathComponent("diag-system-nodrift.caf"))
        let rate = system.rate
        let template = ReferenceSignal.chirp(rate: rate, band: band)
        let periodFrames = period * rate
        let manifest = (try? Data(contentsOf: directory.appendingPathComponent("manifest.json"))).flatMap { try? ManifestJSON.decode($0) }
        let breaks = (manifest?.markers ?? []).filter { $0.kind == .discontinuity }.map { Double($0.atMs) / 1000 }

        func locate(_ reader: MonoReader, center: Double, halfWindow: Double) -> (Double, Float)? {
            let half = Int(halfWindow * rate)
            let start = Int64(center) - Int64(half)
            let segment = reader.read(from: start, count: 2 * half + template.count)
            let count = segment.count - template.count + 1
            guard count > 2 else { return nil }
            var correlation = [Float](repeating: 0, count: count)
            vDSP_conv(segment, 1, template, 1, &correlation, 1, vDSP_Length(count), vDSP_Length(template.count))
            var magnitudes = correlation.map { abs($0) }
            var peak: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(&magnitudes, 1, &peak, &index, vDSP_Length(count))
            var mean: Float = 0
            vDSP_meanv(&magnitudes, 1, &mean, vDSP_Length(count))
            let i = Int(index)
            var delta = 0.0
            if i > 0, i < count - 1 {
                let y0 = Double(magnitudes[i - 1]), y1 = Double(magnitudes[i]), y2 = Double(magnitudes[i + 1])
                let denominator = y0 - 2 * y1 + y2
                if denominator != 0 { delta = 0.5 * (y0 - y2) / denominator }
            }
            return (Double(start) + Double(i) + delta, mean > 0 ? peak / mean : 0)
        }

        // Первый чирп системного канала — в первых двух периодах.
        guard let first = locate(system, center: periodFrames, halfWindow: period), first.1 > 8 else {
            print("опорный сигнал в системном канале не найден"); return
        }
        var predicted = first.0
        var micDelay: Double? = nil
        var misses = 0
        var rows: [(t: Double, sys: Double?, mic: Double?, noDrift: Double?)] = []
        while predicted + periodFrames / 2 < Double(system.length) {
            var sysPos: Double?
            // После двух промахов подряд (разрыв шкалы, ложный пик на краю заполненного тишиной участка)
            // ищем заново в окне целого периода.
            let halfWindow = misses >= 2 ? period * 0.55 : 0.15
            if let hit = locate(system, center: predicted, halfWindow: halfWindow), hit.1 > 8 {
                sysPos = hit.0
                predicted = hit.0
                misses = 0
            } else {
                misses += 1
            }
            var micPos: Double?
            if let sysPos {
                let center = sysPos + (micDelay ?? 0.1 * rate)
                if let hit = locate(mic, center: center, halfWindow: micDelay == nil ? 0.3 : 0.05), hit.1 > 6 {
                    micPos = hit.0
                    micDelay = hit.0 - sysPos
                }
            }
            var noDriftPos: Double?
            if let noDrift, let sysPos, let hit = locate(noDrift, center: sysPos, halfWindow: 0.2), hit.1 > 8 { noDriftPos = hit.0 }
            rows.append((predicted / rate, sysPos, micPos, noDriftPos))
            predicted += periodFrames
        }

        var csv = "t_s,sys_s,mic_s,offset_ms,nodrift_minus_sys_ms\n"
        for row in rows {
            let offset = row.sys.flatMap { s in row.mic.map { ($0 - s) / rate * 1000 } }
            let noDriftOffset = row.sys.flatMap { s in row.noDrift.map { ($0 - s) / rate * 1000 } }
            csv += "\(fmt(row.t, 3)),\(row.sys.map { fmt($0 / rate, 6) } ?? ""),\(row.mic.map { fmt($0 / rate, 6) } ?? ""),"
                + "\(offset.map { fmt($0, 3) } ?? ""),\(noDriftOffset.map { fmt($0, 3) } ?? "")\n"
        }
        if let csvPath { try? csv.write(toFile: csvPath, atomically: true, encoding: .utf8) }

        let bounds = [0.0] + breaks + [Double.infinity]
        print("опорных периодов: \(rows.count), найдено в system: \(rows.filter { $0.sys != nil }.count), в mic: \(rows.filter { $0.mic != nil }.count)")
        print("разрывы (discontinuity), с: \(breaks.map { fmt($0, 3) })")
        var previousTail: Double?
        var previousFit: (a: Double, b: Double)?
        for segment in 0..<(bounds.count - 1) {
            let part = rows.filter { $0.t >= bounds[segment] && $0.t < bounds[segment + 1] }
            let pairs = part.compactMap { row -> (Double, Double)? in
                guard let s = row.sys, let m = row.mic else { return nil }
                return (row.t, (m - s) / rate * 1000)
            }
            let sysPoints = part.compactMap { row in row.sys.map { (row.t, $0) } }
            guard pairs.count >= 3 else { print("сегмент \(segment + 1): мало точек (\(pairs.count))"); continue }
            let offsets = pairs.map(\.1)
            let head = median(Array(offsets.prefix(10))), tail = median(Array(offsets.suffix(10)))
            let hours = (pairs.last!.0 - pairs.first!.0) / 3600
            print("сегмент \(segment + 1) [\(fmt(pairs.first!.0, 1))–\(fmt(pairs.last!.0, 1)) с], пар \(pairs.count):")
            print("  mic−system: медиана \(fmt(median(offsets), 3)) мс, p5 \(fmt(percentile(offsets, 0.05), 3)), p95 \(fmt(percentile(offsets, 0.95), 3)), "
                  + "min \(fmt(offsets.min()!, 3)), max \(fmt(offsets.max()!, 3))")
            print("  начало \(fmt(head, 3)) мс → конец \(fmt(tail, 3)) мс: уход \(fmt(tail - head, 3)) мс за \(fmt(hours * 60, 1)) мин; "
                  + "наклон МНК \(fmt(slope(pairs.map(\.0), offsets) * 3600, 3)) мс/ч")
            if let previousTail { print("  скачок на разрыве: \(fmt(head - previousTail, 3)) мс") }
            previousTail = tail
            // Сетка системного канала: позиция k-го чирпа против идеального периода.
            let ks = sysPoints.map { ($0.1 - sysPoints[0].1) / periodFrames }.map { $0.rounded() }
            let b = slope(ks, sysPoints.map(\.1))
            let a = sysPoints.map(\.1).enumerated().map { $0.element - b * ks[$0.offset] }.reduce(0, +) / Double(sysPoints.count)
            print("  период чирпов в system: \(fmt(b / rate * 1000, 4)) мс при номинале \(fmt(period * 1000, 1)) мс "
                  + "(\(fmt((b / periodFrames - 1) * 1e6, 1)) ppm против часов плеера)")
            if let previousFit, let firstPoint = sysPoints.first {
                let k = ((firstPoint.1 - previousFit.a) / periodFrames).rounded()
                let expected = previousFit.a + previousFit.b * k
                print("  шкала после разрыва: первый чирп смещён на \(fmt((firstPoint.1 - expected) / rate * 1000, 2)) мс против продолжения сетки до разрыва")
            }
            previousFit = (a, b)
            let noDriftOffsets = part.compactMap { row in row.sys.flatMap { s in row.noDrift.map { ($0 - s) / rate * 1000 } } }
            if noDriftOffsets.count > 3 {
                print("  tap без drift compensation − tap с ней: начало \(fmt(median(Array(noDriftOffsets.prefix(10))), 3)) мс, "
                      + "конец \(fmt(median(Array(noDriftOffsets.suffix(10))), 3)) мс, min \(fmt(noDriftOffsets.min()!, 3)), max \(fmt(noDriftOffsets.max()!, 3))")
            }
        }
        if let csvPath { print("CSV: \(csvPath)") }
    }

    // MARK: echo — voice processing против сырого микрофона (R6)

    static func echo(directory: URL, phases: [(String, Double, Double)]) {
        guard let system = try? MonoReader(directory.appendingPathComponent("audio-system.caf")),
              let raw = try? MonoReader(directory.appendingPathComponent("audio-mic.caf")) else {
            print("нужны audio-system.caf и audio-mic.caf"); return
        }
        let vp = try? MonoReader(directory.appendingPathComponent("diag-mic-vp.caf"))
        let rate = raw.rate
        let systemSamples = system.readAll(), rawSamples = raw.readAll()
        var vpSamples = vp.map { resample($0.readAll(), from: $0.rate, to: rate) } ?? []

        // Выравнивание VP против сырого микрофона по взаимной корреляции на фазе ближней речи.
        if !vpSamples.isEmpty, let near = phases.first(where: { $0.0 == "near" }) ?? phases.first {
            let lag = bestLag(reference: rawSamples, other: vpSamples, from: near.1, to: near.2, rate: rate, maxLag: 0.5)
            print("VP относительно сырого микрофона: задержка \(fmt(lag.seconds * 1000, 1)) мс, корреляция \(fmt(lag.coefficient, 3))")
            let shift = Int((lag.seconds * rate).rounded())
            if shift > 0 { vpSamples = Array(vpSamples.dropFirst(shift)) } else if shift < 0 { vpSamples = [Float](repeating: 0, count: -shift) + vpSamples }
        }
        func slice(_ samples: [Float], _ from: Double, _ to: Double) -> ArraySlice<Float> {
            let a = min(samples.count, Int(from * rate)), b = min(samples.count, Int(to * rate))
            return samples[a..<max(a, b)]
        }
        print("\nфаза\tsystem dBFS\tmic raw dBFS\tmic VP dBFS\traw−VP дБ\tкорр. system↔raw\tкорр. system↔VP")
        var levels: [String: (sys: Double, raw: Double, vp: Double)] = [:]
        for (name, from, to) in phases {
            let s = rmsDB(slice(systemSamples, from, to)), r = rmsDB(slice(rawSamples, from, to))
            let v = vpSamples.isEmpty ? Double.nan : rmsDB(slice(vpSamples, from, to))
            levels[name] = (s, r, v)
            let corrRaw = bestLag(reference: systemSamples, other: rawSamples, from: from, to: to, rate: rate, maxLag: 0.3).coefficient
            let corrVP = vpSamples.isEmpty ? Double.nan
                : bestLag(reference: systemSamples, other: vpSamples, from: from, to: to, rate: rate, maxLag: 0.3).coefficient
            print("\(name) [\(fmt(from, 0))–\(fmt(to, 0)) с]\t\(fmt(s))\t\(fmt(r))\t\(fmt(v))\t\(fmt(r - v))\t\(fmt(corrRaw, 3))\t\(fmt(corrVP, 3))")
        }
        if let far = levels["far"], let near = levels["near"] {
            print("\nэхо в микрофонном канале (фаза far, говорит только «собеседник»): raw \(fmt(far.raw - far.sys)) дБ к системному каналу, "
                  + "VP \(fmt(far.vp - far.sys)) дБ; подавление VP \(fmt(far.raw - far.vp)) дБ")
            print("сигнал/эхо: речь пользователя (near) против эха (far): raw \(fmt(near.raw - far.raw)) дБ, VP \(fmt(near.vp - far.vp)) дБ")
            if let double = levels["double"] {
                print("двойной разговор: уровень VP \(fmt(double.vp)) против near \(fmt(near.vp)) (\(fmt(double.vp - near.vp)) дБ); "
                      + "raw \(fmt(double.raw)) против near \(fmt(near.raw)) (\(fmt(double.raw - near.raw)) дБ)")
            }
        }
        if !vpSamples.isEmpty, let near = phases.first(where: { $0.0 == "near" }) {
            let rawBands = bandLevels(Array(slice(rawSamples, near.1, near.2)), rate: rate)
            let vpBands = bandLevels(Array(slice(vpSamples, near.1, near.2)), rate: rate)
            let rawTotal = rmsDB(slice(rawSamples, near.1, near.2)), vpTotal = rmsDB(slice(vpSamples, near.1, near.2))
            print("\nокраска на ближней речи (1/3 октавы, разница VP−raw после выравнивания общего уровня на \(fmt(vpTotal - rawTotal)) дБ):")
            print("Гц\traw дБ\tVP дБ\tVP−raw дБ")
            for (index, band) in rawBands.enumerated() where index < vpBands.count {
                let diff = (vpBands[index].1 - rawBands[index].1) - (vpTotal - rawTotal)
                print("\(Int(band.0))\t\(fmt(band.1))\t\(fmt(vpBands[index].1))\t\(fmt(diff))")
            }
        }
    }

    // MARK: r6 — сравнение прогона raw и прогона VP (scripts/r6-echo.sh)

    /// Фазы отсчитываются от начала речи «собеседника» в системном канале (t0):
    /// far — [t0+1, t0+34] (говорит только собеседник), near — [t0+37, t0+58] (читает только человек),
    /// double — [t0+81, t0+110] (оба). Для raw берётся audio-mic.caf, для VP — diag-mic-vp.caf.
    static func compareR6(rawDirectory: URL, vpDirectory: URL) {
        struct Run {
            let name: String
            let system: [Float]
            let channel: [Float]
            let rate: Double
            let t0: Double
        }
        func load(_ directory: URL, channelFile: String, name: String) -> Run? {
            guard let system = try? MonoReader(directory.appendingPathComponent("audio-system.caf")),
                  let channel = try? MonoReader(directory.appendingPathComponent(channelFile)) else { return nil }
            let systemSamples = system.readAll()
            let channelSamples = resample(channel.readAll(), from: channel.rate, to: system.rate)
            let window = Int(0.05 * system.rate)
            var onset = 0.0
            var index = 0
            while index + window < systemSamples.count {
                if rmsDB(systemSamples[index..<index + window]) > -45 { onset = Double(index) / system.rate; break }
                index += window
            }
            return Run(name: name, system: systemSamples, channel: channelSamples, rate: system.rate, t0: onset)
        }
        guard let raw = load(rawDirectory, channelFile: "audio-mic.caf", name: "raw"),
              let vp = load(vpDirectory, channelFile: "diag-mic-vp.caf", name: "VP") else {
            print("нужны audio-system.caf, audio-mic.caf (raw) и diag-mic-vp.caf (VP)"); return
        }
        let phases: [(String, Double, Double)] = [("far", 1, 34), ("near", 37, 58), ("double", 81, 110)]
        func slice(_ samples: [Float], _ run: Run, _ from: Double, _ to: Double) -> ArraySlice<Float> {
            let a = min(samples.count, Int((run.t0 + from) * run.rate)), b = min(samples.count, Int((run.t0 + to) * run.rate))
            return samples[a..<max(a, b)]
        }
        var levels: [String: [String: (sys: Double, ch: Double, corr: Double)]] = [:]
        print("прогон\tt0, с\tфаза\tsystem dBFS\tканал dBFS\tканал−system дБ\tкорр. огибающих system↔канал")
        for run in [raw, vp] {
            for (phase, from, to) in phases {
                let s = rmsDB(slice(run.system, run, from, to)), c = rmsDB(slice(run.channel, run, from, to))
                let corr = bestLag(reference: run.system, other: run.channel, from: run.t0 + from, to: run.t0 + to,
                                   rate: run.rate, maxLag: 0.3).coefficient
                levels[run.name, default: [:]][phase] = (s, c, corr)
                print("\(run.name)\t\(fmt(run.t0, 2))\t\(phase)\t\(fmt(s))\t\(fmt(c))\t\(fmt(c - s))\t\(fmt(corr, 3))")
            }
        }
        if let r = levels["raw"], let v = levels["VP"], let rf = r["far"], let rn = r["near"], let vf = v["far"], let vn = v["near"],
           let rd = r["double"], let vd = v["double"] {
            print("\nэхо собеседника в канале пользователя (фаза far): raw \(fmt(rf.ch)) dBFS, VP \(fmt(vf.ch)) dBFS")
            print("ducking системного звука от VP: \(fmt(rf.sys - vf.sys)) дБ (system raw \(fmt(rf.sys)) против VP \(fmt(vf.sys)))")
            print("речь пользователя / эхо (near − far): raw \(fmt(rn.ch - rf.ch)) дБ, VP \(fmt(vn.ch - vf.ch)) дБ")
            print("двойной разговор против чистой речи пользователя (double − near): raw \(fmt(rd.ch - rn.ch)) дБ, VP \(fmt(vd.ch - vn.ch)) дБ")
            print("усиление речи пользователя VP против raw (near): \(fmt(vn.ch - rn.ch)) дБ")
        }
        let rawBands = bandLevels(Array(slice(raw.channel, raw, 37, 58)), rate: raw.rate)
        let vpBands = bandLevels(Array(slice(vp.channel, vp, 37, 58)), rate: vp.rate)
        let rawTotal = rmsDB(slice(raw.channel, raw, 37, 58)), vpTotal = rmsDB(slice(vp.channel, vp, 37, 58))
        let rawFar = bandLevels(Array(slice(raw.channel, raw, 1, 34)), rate: raw.rate)
        let vpFar = bandLevels(Array(slice(vp.channel, vp, 1, 34)), rate: vp.rate)
        print("\nокраска речи пользователя: 1/3 октавы фазы near, VP−raw после выравнивания общего уровня (\(fmt(vpTotal - rawTotal)) дБ);")
        print("эхо по полосам: near−far в каждом канале (сколько речь пользователя выше эха в полосе)")
        print("Гц\tVP−raw near дБ\traw near−far дБ\tVP near−far дБ")
        for index in rawBands.indices where index < vpBands.count && index < rawFar.count && index < vpFar.count {
            let coloring = (vpBands[index].1 - rawBands[index].1) - (vpTotal - rawTotal)
            print("\(Int(rawBands[index].0))\t\(fmt(coloring))\t\(fmt(rawBands[index].1 - rawFar[index].1))\t\(fmt(vpBands[index].1 - vpFar[index].1))")
        }
    }

    static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, !samples.isEmpty,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(samples.count) * to / from) + 1024)
        else { return samples }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var supplied = false
        converter.convert(to: output, error: nil) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// Лаг `other` относительно `reference` (положительный — `other` отстаёт) и нормированная корреляция.
    /// Считается на огибающей, прорежённой до 1 кГц: для эха и выравнивания этого достаточно.
    static func bestLag(reference: [Float], other: [Float], from: Double, to: Double, rate: Double, maxLag: Double) -> (seconds: Double, coefficient: Double) {
        let decimation = Int(rate / 1000)
        func envelope(_ samples: [Float], _ a: Int, _ b: Int) -> [Float] {
            guard a < b else { return [] }
            var out: [Float] = []
            out.reserveCapacity((b - a) / decimation + 1)
            var index = a
            while index + decimation <= b {
                var sum: Float = 0
                for j in index..<index + decimation { sum += abs(samples[j]) }
                out.append(sum / Float(decimation))
                index += decimation
            }
            let mean = out.reduce(0, +) / Float(max(out.count, 1))
            return out.map { $0 - mean }
        }
        let lagSamples = Int(maxLag * rate)
        let a = Int(from * rate), b = Int(to * rate)
        guard b <= reference.count, b + lagSamples <= other.count, a >= lagSamples else {
            let bb = min(b, reference.count, other.count - lagSamples)
            guard bb > a else { return (0, 0) }
            return bestLag(reference: reference, other: other, from: from, to: Double(bb) / rate, rate: rate, maxLag: maxLag)
        }
        let ref = envelope(reference, a, b)
        let oth = envelope(other, a - lagSamples, b + lagSamples)
        let lags = oth.count - ref.count + 1
        guard lags > 0, !ref.isEmpty else { return (0, 0) }
        var correlation = [Float](repeating: 0, count: lags)
        vDSP_conv(oth, 1, ref, 1, &correlation, 1, vDSP_Length(lags), vDSP_Length(ref.count))
        var peak: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(correlation, 1, &peak, &index, vDSP_Length(lags))
        var refEnergy: Float = 0
        vDSP_svesq(ref, 1, &refEnergy, vDSP_Length(ref.count))
        let window = Array(oth[Int(index)..<Int(index) + ref.count])
        var otherEnergy: Float = 0
        vDSP_svesq(window, 1, &otherEnergy, vDSP_Length(window.count))
        let coefficient = refEnergy > 0 && otherEnergy > 0 ? Double(peak) / Double(sqrt(refEnergy * otherEnergy)) : 0
        let lag = (Double(index) - Double(lagSamples / decimation)) * Double(decimation) / rate
        return (lag, coefficient)
    }

    /// Уровни в третьоктавных полосах 100 Гц – 16 кГц по усреднённому спектру (окно Ханна 4096, шаг 2048).
    static func bandLevels(_ samples: [Float], rate: Double) -> [(Double, Double)] {
        let n = 4096, half = n / 2
        guard samples.count >= n, let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else { return [] }
        defer { vDSP_DFT_DestroySetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var power = [Double](repeating: 0, count: half)
        var frames = 0
        var inReal = [Float](repeating: 0, count: half), inImag = [Float](repeating: 0, count: half)
        var outReal = [Float](repeating: 0, count: half), outImag = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: n)
        var start = 0
        while start + n <= samples.count {
            samples.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n)) }
            for i in 0..<half { inReal[i] = windowed[2 * i]; inImag[i] = windowed[2 * i + 1] }
            vDSP_DFT_Execute(setup, inReal, inImag, &outReal, &outImag)
            for i in 0..<half { power[i] += Double(outReal[i] * outReal[i] + outImag[i] * outImag[i]) }
            frames += 1
            start += half
        }
        let binHz = rate / Double(n)
        var bands: [(Double, Double)] = []
        var center = 100.0
        while center <= min(16000, rate / 2 / pow(2, 1.0 / 6)) {
            let low = Int(center / pow(2, 1.0 / 6) / binHz), high = max(low + 1, Int(center * pow(2, 1.0 / 6) / binHz))
            let sum = power[low..<min(high, half)].reduce(0, +) / Double(max(frames, 1))
            bands.append((center, sum > 0 ? 10 * log10(sum) : -200))
            center *= pow(2, 1.0 / 3)
        }
        return bands
    }
}
