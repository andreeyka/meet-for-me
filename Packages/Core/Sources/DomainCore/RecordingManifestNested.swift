//  Вложенные типы C-002.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  `Channel` случая `unknown` не имеет и на незнакомом значении отказывает: канал — сигнал
//  атрибуции, а не описательный ярлык. `MarkerKind` и `DiscontinuityReason` такой случай имеют.

import Foundation

extension RecordingManifest {

    /// Канал записи. Случая `unknown` нет намеренно.
    public enum Channel: String, Codable, Sendable {
        case mic
        case system
    }

    /// Дорожка на диске.
    public struct Track: Codable, Equatable, Sendable, DomainValidatable {
        public let channel: Channel
        /// Имя файла относительно каталога записи, один компонент пути.
        public let fileName: String
        public let sampleRate: Int
        public let channelCount: Int
        public let format: String

        public init(channel: Channel, fileName: String, sampleRate: Int,
                    channelCount: Int, format: String) throws {
            self.channel = channel
            self.fileName = fileName
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.format = format
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            channel = try box.decode(Channel.self, forKey: .channel)
            fileName = try box.decode(String.self, forKey: .fileName)
            sampleRate = try box.decodeBounded(Int.self, forKey: .sampleRate)
            channelCount = try box.decodeBounded(Int.self, forKey: .channelCount)
            format = try box.decode(String.self, forKey: .format)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(channel, forKey: .channel)
            try box.encode(fileName, forKey: .fileName)
            try box.encode(sampleRate, forKey: .sampleRate)
            try box.encode(channelCount, forKey: .channelCount)
            try box.encode(format, forKey: .format)
        }

        public func validate() throws {
            let owner = DomainOwner(contract: "C-002", type: "RecordingManifest.Track")
            try owner.requireInt(sampleRate, "sampleRate")
            try owner.requireInt(channelCount, "channelCount")
            try owner.check(Track.isSinglePathComponent(fileName), 3, "fileName",
                            "имя не является одним компонентом пути: \(fileName)")
            try owner.check(format == "pcm-caf" || format == "aac-m4a", 5, "format",
                            "формат вне множества pcm-caf | aac-m4a: \(format)")
            try owner.check(sampleRate > 0, 6, "sampleRate", "частота не положительна")
            try owner.check(channelCount > 0, 6, "channelCount", "число каналов не положительно")
        }

        /// Инвариант 3. Длина считается в байтах UTF-8, а не в символах.
        static func isSinglePathComponent(_ name: String) -> Bool {
            guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix(".") else { return false }
            guard !name.contains("/"), !name.contains("\\") else { return false }
            guard !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return false }
            return name.utf8.count <= 255
        }
    }

    /// Вид маркера. Случай `unknown` объявлен контрактом (C-001 §0.3).
    public enum MarkerKind: String, Codable, Sendable {
        case pause
        case resume
        case sleep
        case wake
        case deviceChanged
        case discontinuity
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = MarkerKind(rawValue: raw) ?? .unknown
        }
    }

    /// Отметка на шкале записи.
    public struct Marker: Codable, Equatable, Sendable, DomainValidatable {
        public let kind: MarkerKind
        public let atMs: Int
        /// Описательная строка; разбирать её потребитель не обязан и не вправе.
        public let detail: String?

        public init(kind: MarkerKind, atMs: Int, detail: String?) throws {
            self.kind = kind
            self.atMs = atMs
            self.detail = detail
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            kind = try box.decode(MarkerKind.self, forKey: .kind)
            atMs = try box.decodeBounded(Int.self, forKey: .atMs)
            detail = try box.decodeIfPresent(String.self, forKey: .detail)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(kind, forKey: .kind)
            try box.encode(atMs, forKey: .atMs)
            try box.encodeIfPresent(detail, forKey: .detail)
        }

        public func validate() throws {
            let owner = DomainOwner(contract: "C-002", type: "RecordingManifest.Marker")
            try owner.requireInt(atMs, "atMs")
            try owner.check(atMs >= 0, 8, "atMs", "atMs отрицателен")
            try owner.check(detail != "", 16, "detail", "пустая строка не значение")
        }
    }

    /// Процесс, попадавший в tap за время записи.
    public struct CapturedProcess: Codable, Equatable, Sendable, DomainValidatable {
        public let pid: Int32
        public let bundleId: String?
        public let executableName: String?

        public init(pid: Int32, bundleId: String?, executableName: String?) throws {
            self.pid = pid
            self.bundleId = bundleId
            self.executableName = executableName
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            pid = try box.decodeBounded(Int32.self, forKey: .pid)
            bundleId = try box.decodeIfPresent(String.self, forKey: .bundleId)
            executableName = try box.decodeIfPresent(String.self, forKey: .executableName)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(pid, forKey: .pid)
            try box.encodeIfPresent(bundleId, forKey: .bundleId)
            try box.encodeIfPresent(executableName, forKey: .executableName)
        }

        public func validate() throws {
            let owner = DomainOwner(contract: "C-002", type: "RecordingManifest.CapturedProcess")
            try owner.requireInt32(pid, "pid")
            try owner.check(bundleId != "", 16, "bundleId", "пустая строка не значение")
            try owner.check(executableName != "", 16, "executableName", "пустая строка не значение")
        }
    }

    /// Причина разрыва шкалы. Случай `unknown` объявлен контрактом.
    public enum DiscontinuityReason: String, Codable, Sendable {
        case rebuild
        case sleep
        case sourceGone
        case dropped
        case truncated
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = DiscontinuityReason(rawValue: raw) ?? .unknown
        }
    }

    /// Разрыв временной шкалы. Ровно один элемент на каждый маркер `.discontinuity`.
    public struct Discontinuity: Codable, Equatable, Sendable, DomainValidatable {
        public let atMs: Int
        /// Сколько миллисекунд шкалы не содержат записанного звука.
        public let gapMs: Int
        /// Оценка сверху для ошибки, которую разрыв вносит во всё, что после него.
        public let scaleErrorMs: Int
        public let reason: DiscontinuityReason

        public init(atMs: Int, gapMs: Int, scaleErrorMs: Int, reason: DiscontinuityReason) throws {
            self.atMs = atMs
            self.gapMs = gapMs
            self.scaleErrorMs = scaleErrorMs
            self.reason = reason
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            atMs = try box.decodeBounded(Int.self, forKey: .atMs)
            gapMs = try box.decodeBounded(Int.self, forKey: .gapMs)
            scaleErrorMs = try box.decodeBounded(Int.self, forKey: .scaleErrorMs)
            reason = try box.decode(DiscontinuityReason.self, forKey: .reason)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(atMs, forKey: .atMs)
            try box.encode(gapMs, forKey: .gapMs)
            try box.encode(scaleErrorMs, forKey: .scaleErrorMs)
            try box.encode(reason, forKey: .reason)
        }

        public func validate() throws {
            let owner = DomainOwner(contract: "C-002", type: "RecordingManifest.Discontinuity")
            try owner.requireInt(atMs, "atMs")
            try owner.requireInt(gapMs, "gapMs")
            try owner.requireInt(scaleErrorMs, "scaleErrorMs")
            try owner.check(atMs >= 0, 14, "atMs", "atMs отрицателен")
            try owner.check(gapMs >= 0, 14, "gapMs", "gapMs отрицателен")
            try owner.check(scaleErrorMs >= 0, 14, "scaleErrorMs", "scaleErrorMs отрицателен")
        }
    }

    /// Состояние входа, действующее с момента `atMs` и до следующего элемента массива.
    public struct InputDeviceSpan: Codable, Equatable, Sendable, DomainValidatable {
        public let atMs: Int
        /// `false` — устройства ввода нет с этого момента.
        public let present: Bool
        public let name: String?
        public let uid: String?

        public init(atMs: Int, present: Bool, name: String?, uid: String?) throws {
            self.atMs = atMs
            self.present = present
            self.name = name
            self.uid = uid
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            atMs = try box.decodeBounded(Int.self, forKey: .atMs)
            present = try box.decode(Bool.self, forKey: .present)
            name = try box.decodeIfPresent(String.self, forKey: .name)
            uid = try box.decodeIfPresent(String.self, forKey: .uid)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(atMs, forKey: .atMs)
            try box.encode(present, forKey: .present)
            try box.encodeIfPresent(name, forKey: .name)
            try box.encodeIfPresent(uid, forKey: .uid)
        }

        public func validate() throws {
            let owner = DomainOwner(contract: "C-002", type: "RecordingManifest.InputDeviceSpan")
            try owner.requireInt(atMs, "atMs")
            try owner.check(atMs >= 0, 9, "atMs", "atMs отрицателен")
            try owner.check(name != "", 16, "name", "пустая строка не значение")
            try owner.check(uid != "", 16, "uid", "пустая строка не значение")
            guard !present else { return }
            try owner.check(name == nil, 17, "name", "устройства нет, а имя названо")
            try owner.check(uid == nil, 17, "uid", "устройства нет, а UID назван")
        }
    }
}

extension RecordingManifest.Track {
    enum CodingKeys: String, CodingKey {
        case channel, fileName, sampleRate, channelCount, format
    }
}

extension RecordingManifest.Marker {
    enum CodingKeys: String, CodingKey {
        case kind, atMs, detail
    }
}

extension RecordingManifest.CapturedProcess {
    enum CodingKeys: String, CodingKey {
        case pid, bundleId, executableName
    }
}

extension RecordingManifest.Discontinuity {
    enum CodingKeys: String, CodingKey {
        case atMs, gapMs, scaleErrorMs, reason
    }
}

extension RecordingManifest.InputDeviceSpan {
    enum CodingKeys: String, CodingKey {
        case atMs, present, name, uid
    }
}
