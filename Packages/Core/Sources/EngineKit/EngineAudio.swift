//  AudioRef, AudioSlice — C-011 v5 «Определение» §1: ссылка на аудио записи и его вырезка.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)

import DomainCore
import Foundation

/// Ссылка на дорожку записи, а не сами сэмплы: движок читает файл по `fileURL` сам.
public struct AudioRef: Codable, Equatable, Sendable, DomainValidatable {
    public let recordingId: UUID
    public let channel: RecordingManifest.Channel
    public let fileURL: URL
    public let sampleRate: Int
    public let channelCount: Int
    public let offsetMs: Int

    public init(
        recordingId: UUID, channel: RecordingManifest.Channel, fileURL: URL,
        sampleRate: Int, channelCount: Int, offsetMs: Int
    ) throws {
        self.recordingId = recordingId
        self.channel = channel
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.offsetMs = offsetMs
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case recordingId, channel, fileURL, sampleRate, channelCount, offsetMs
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        recordingId = try box.decode(UUID.self, forKey: .recordingId)
        channel = try box.decode(RecordingManifest.Channel.self, forKey: .channel)
        fileURL = try box.decode(URL.self, forKey: .fileURL)
        sampleRate = try box.decodeBounded(Int.self, forKey: .sampleRate)
        channelCount = try box.decodeBounded(Int.self, forKey: .channelCount)
        offsetMs = try box.decodeBounded(Int.self, forKey: .offsetMs)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(recordingId, forKey: .recordingId)
        try box.encode(channel, forKey: .channel)
        try box.encode(fileURL, forKey: .fileURL)
        try box.encode(sampleRate, forKey: .sampleRate)
        try box.encode(channelCount, forKey: .channelCount)
        try box.encode(offsetMs, forKey: .offsetMs)
    }

    public func validate() throws {
        let owner = EngineOwner(contract: "C-001", type: "AudioRef")
        try owner.requireInt(sampleRate, "sampleRate")
        try owner.requireInt(channelCount, "channelCount")
        try owner.requireInt(offsetMs, "offsetMs")
    }
}

/// Вырезка `source` на его собственной шкале (после `offsetMs`, не до).
public struct AudioSlice: Codable, Equatable, Sendable, DomainValidatable {
    public let source: AudioRef
    public let startMs: Int
    public let endMs: Int

    public init(source: AudioRef, startMs: Int, endMs: Int) throws {
        self.source = source
        self.startMs = startMs
        self.endMs = endMs
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case source, startMs, endMs
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        source = try box.decode(AudioRef.self, forKey: .source)
        startMs = try box.decodeBounded(Int.self, forKey: .startMs)
        endMs = try box.decodeBounded(Int.self, forKey: .endMs)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(source, forKey: .source)
        try box.encode(startMs, forKey: .startMs)
        try box.encode(endMs, forKey: .endMs)
    }

    public func validate() throws {
        try source.validate()
        let owner = EngineOwner(contract: "C-001", type: "AudioSlice")
        try owner.requireInt(startMs, "startMs")
        try owner.requireInt(endMs, "endMs")
    }
}
