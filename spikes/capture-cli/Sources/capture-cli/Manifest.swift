import Foundation

// Зеркало C-002 v2 RecordingManifest (MEE-3) и правил кодирования C-001 §0.4 (MEE-2).
// DomainCore пока скелет, поэтому спайк держит копию: поля, инварианты 1–13, компактный JSON
// с .sortedKeys и .withoutEscapingSlashes, Date — YYYY-MM-DDThh:mm:ss.sssZ, nil-ключи опускаются.

struct RecordingManifest: Codable, Equatable {
    static let currentSchemaVersion = 2

    enum Channel: String, Codable { case mic, system }

    struct Track: Codable, Equatable {
        var channel: Channel
        var fileName: String
        var sampleRate: Int
        var channelCount: Int
        var format: String
    }

    enum MarkerKind: String, Codable {
        case pause, resume, sleep, wake, deviceChanged, discontinuity, unknown

        init(from decoder: Decoder) throws {
            self = MarkerKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    struct Marker: Codable, Equatable {
        var kind: MarkerKind
        var atMs: Int
        var detail: String?
    }

    struct CapturedProcess: Codable, Equatable {
        var pid: Int32
        var bundleId: String?
        var executableName: String?
    }

    struct InputDeviceSpan: Codable, Equatable {
        var atMs: Int
        var name: String?
        var uid: String?
    }

    var schemaVersion = RecordingManifest.currentSchemaVersion
    var recordingId: UUID
    var meetingId: UUID?
    var directoryName: String
    var startedAt: Date
    var endedAt: Date?
    var tracks: [Track]
    var markers: [Marker]
    var capturedProcesses: [CapturedProcess]
    var inputDevices: [InputDeviceSpan]
    var isFinalized: Bool

    /// Возвращает первое нарушение в виде «C-002 инв. N, path: message» или nil.
    func firstViolation() -> String? {
        func fail(_ invariant: Int, _ path: String, _ message: String) -> String {
            "C-002 инв. \(invariant), \(path): \(message)"
        }
        if schemaVersion != Self.currentSchemaVersion {
            return fail(1, "schemaVersion", "файл версии \(schemaVersion), код версии \(Self.currentSchemaVersion)")
        }
        if tracks.isEmpty { return fail(2, "tracks", "пустой") }
        if Set(tracks.map(\.channel)).count != tracks.count { return fail(2, "tracks", "два трека одного канала") }
        for (index, track) in tracks.enumerated() {
            let name = track.fileName
            let badScalar = name.unicodeScalars.contains { $0.value < 0x20 || $0 == "/" || $0 == "\\" }
            if name.isEmpty || name == "." || name == ".." || badScalar || name.hasPrefix(".") || name.utf8.count > 255 {
                return fail(3, "tracks[\(index)].fileName", "не один компонент пути: \(name)")
            }
        }
        if Set(tracks.map(\.fileName)).count != tracks.count { return fail(4, "tracks", "fileName не уникален") }
        if let index = tracks.firstIndex(where: { !["pcm-caf", "aac-m4a"].contains($0.format) }) {
            return fail(5, "tracks[\(index)].format", tracks[index].format)
        }
        if let index = tracks.firstIndex(where: { $0.sampleRate <= 0 || $0.channelCount <= 0 }) {
            return fail(6, "tracks[\(index)]", "sampleRate/channelCount <= 0")
        }
        if directoryName != recordingId.uuidString { return fail(7, "directoryName", directoryName) }
        for index in markers.indices {
            if markers[index].atMs < 0 { return fail(8, "markers[\(index)].atMs", "< 0") }
            if index > 0, markers[index].atMs < markers[index - 1].atMs { return fail(8, "markers[\(index)]", "убывает") }
        }
        for index in inputDevices.indices {
            if inputDevices[index].atMs < 0 { return fail(9, "inputDevices[\(index)].atMs", "< 0") }
            if index > 0, inputDevices[index].atMs <= inputDevices[index - 1].atMs {
                return fail(9, "inputDevices[\(index)]", "не строго возрастает")
            }
        }
        if let first = inputDevices.first, first.atMs != 0 { return fail(9, "inputDevices[0].atMs", "\(first.atMs) != 0") }
        let changeTimes = Set(markers.filter { $0.kind == .deviceChanged }.map(\.atMs))
        let spanTimes = Set(inputDevices.filter { $0.atMs > 0 }.map(\.atMs))
        if changeTimes != spanTimes {
            return fail(10, "inputDevices", "спаны \(spanTimes.sorted()) != маркеры deviceChanged \(changeTimes.sorted())")
        }
        if let endedAt {
            let durationMs = Int((endedAt.timeIntervalSince(startedAt) * 1000).rounded())
            if let marker = markers.first(where: { $0.atMs > durationMs }) {
                return fail(11, "markers", "atMs \(marker.atMs) > durationMs \(durationMs)")
            }
            if let span = inputDevices.first(where: { $0.atMs > durationMs }) {
                return fail(11, "inputDevices", "atMs \(span.atMs) > durationMs \(durationMs)")
            }
            if endedAt < startedAt { return fail(12, "endedAt", "раньше startedAt") }
        }
        if isFinalized, endedAt == nil || tracks.contains(where: { $0.format != "aac-m4a" }) {
            return fail(13, "isFinalized", "true без endedAt или не aac-m4a")
        }
        return nil
    }
}

enum ManifestJSON {
    static func encode(_ manifest: RecordingManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return try encoder.encode(manifest)
    }

    static func decode(_ data: Data) throws -> RecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "дата не по C-001 §0.4: \(string)")
            }
            return date
        }
        return try decoder.decode(RecordingManifest.self, from: data)
    }

    /// Запись во временный файл рядом и rename — атомарно для читателя и после kill -9.
    static func writeAtomically(_ manifest: RecordingManifest, to directory: URL) throws {
        let data = try encode(manifest)
        let temporary = directory.appendingPathComponent("manifest.json.tmp")
        let target = directory.appendingPathComponent("manifest.json")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        fsync(fd)
        close(fd)
        guard rename(temporary.path, target.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    static func roundedToMs(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.toNearestOrAwayFromZero) / 1000)
    }

    static func formatDate(_ date: Date) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded(.toNearestOrAwayFromZero))
        var seconds = time_t(totalMs.floorDiv(1000))
        let ms = totalMs - Int64(seconds) * 1000
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", parts.tm_year + 1900, parts.tm_mon + 1,
                      parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec, Int(ms))
    }

    static func parseDate(_ string: String) -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: string).map { String(string[$0]) }
        }
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = Int(group(1)!); components.month = Int(group(2)!); components.day = Int(group(3)!)
        components.hour = Int(group(4)!); components.minute = Int(group(5)!); components.second = Int(group(6)!)
        guard let base = Calendar(identifier: .gregorian).date(from: components) else { return nil }
        let fraction = group(7).flatMap { Double("0" + $0) } ?? 0
        var offset: TimeInterval = 0
        if let zone = group(8), zone != "Z" {
            let sign: Double = zone.hasPrefix("-") ? -1 : 1
            let hours = Double(zone.dropFirst().prefix(2))!, minutes = Double(zone.suffix(2))!
            offset = sign * (hours * 3600 + minutes * 60)
        }
        return roundedToMs(base.addingTimeInterval(fraction - offset))
    }
}

private extension Int64 {
    func floorDiv(_ divisor: Int64) -> Int64 {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}
