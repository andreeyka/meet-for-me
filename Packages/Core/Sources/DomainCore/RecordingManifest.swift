//  RecordingManifest — DTO и формат файла `manifest.json` контракта C-002.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  `atMs` — позиция в опорном треке, а не время по часам; этот тип её хранит и проверяет,
//  а смысл шкалы задаёт раздел «Поведение» контракта.

import Foundation

/// Манифест записи: описание того, что легло на диск.
public struct RecordingManifest: Codable, Equatable, Sendable, DomainValidatable {

    /// Версия схемы файла, которую пишет и принимает этот код.
    public static let currentSchemaVersion: Int = 3

    public let schemaVersion: Int
    public let recordingId: UUID
    /// `nil` для ad-hoc созвона без события в календаре.
    public let meetingId: UUID?
    public let directoryName: String
    public let startedAt: Date
    /// `nil`, пока запись не завершена.
    public let endedAt: Date?
    public let tracks: [Track]
    public let markers: [Marker]
    /// Объединение за всю запись, не снимок на старте.
    public let capturedProcesses: [CapturedProcess]
    /// Непрозрачный ключ группы захвата; смысл задаёт C-004.
    public let captureGroupKey: String?
    public let inputDevices: [InputDeviceSpan]
    public let discontinuities: [Discontinuity]
    public let isFinalized: Bool

    public init(
        schemaVersion: Int = RecordingManifest.currentSchemaVersion,
        recordingId: UUID,
        meetingId: UUID?,
        directoryName: String,
        startedAt: Date,
        endedAt: Date?,
        tracks: [Track],
        markers: [Marker],
        capturedProcesses: [CapturedProcess],
        captureGroupKey: String?,
        inputDevices: [InputDeviceSpan],
        discontinuities: [Discontinuity],
        isFinalized: Bool
    ) throws {
        self.schemaVersion = schemaVersion
        self.recordingId = recordingId
        self.meetingId = meetingId
        self.directoryName = directoryName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tracks = tracks
        self.markers = markers
        self.capturedProcesses = capturedProcesses
        self.captureGroupKey = captureGroupKey
        self.inputDevices = inputDevices
        self.discontinuities = discontinuities
        self.isFinalized = isFinalized
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, recordingId, meetingId, directoryName, startedAt, endedAt
        case tracks, markers, capturedProcesses, captureGroupKey, inputDevices
        case discontinuities, isFinalized
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decodeBounded(Int.self, forKey: .schemaVersion)
        recordingId = try box.decode(UUID.self, forKey: .recordingId)
        meetingId = try box.decodeIfPresent(UUID.self, forKey: .meetingId)
        directoryName = try box.decode(String.self, forKey: .directoryName)
        startedAt = try box.decode(Date.self, forKey: .startedAt)
        endedAt = try box.decodeIfPresent(Date.self, forKey: .endedAt)
        tracks = try box.decode([Track].self, forKey: .tracks)
        markers = try box.decode([Marker].self, forKey: .markers)
        capturedProcesses = try box.decode([CapturedProcess].self, forKey: .capturedProcesses)
        captureGroupKey = try box.decodeIfPresent(String.self, forKey: .captureGroupKey)
        inputDevices = try box.decode([InputDeviceSpan].self, forKey: .inputDevices)
        discontinuities = try box.decode([Discontinuity].self, forKey: .discontinuities)
        isFinalized = try box.decode(Bool.self, forKey: .isFinalized)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(schemaVersion, forKey: .schemaVersion)
        try box.encode(recordingId, forKey: .recordingId)
        try box.encodeIfPresent(meetingId, forKey: .meetingId)
        try box.encode(directoryName, forKey: .directoryName)
        try box.encode(startedAt, forKey: .startedAt)
        try box.encodeIfPresent(endedAt, forKey: .endedAt)
        try box.encode(tracks, forKey: .tracks)
        try box.encode(markers, forKey: .markers)
        try box.encode(capturedProcesses, forKey: .capturedProcesses)
        try box.encodeIfPresent(captureGroupKey, forKey: .captureGroupKey)
        try box.encode(inputDevices, forKey: .inputDevices)
        try box.encode(discontinuities, forKey: .discontinuities)
        try box.encode(isFinalized, forKey: .isFinalized)
    }

    /// Ступени §0.2 п. 6: (а) вложенные значения → (в) представимость → (б) собственные
    /// инварианты в порядке номеров.
    public func validate() throws {
        let owner = DomainOwner(contract: "C-002", type: "RecordingManifest")
        try validateNested()
        try owner.requireInt(schemaVersion, "schemaVersion")
        try owner.requireDate(startedAt, "startedAt")
        try owner.requireDate(endedAt, "endedAt")
        try validateShape(owner)
        try validateOrdering(owner)
        try validateBounds(owner)
        try validateDiscontinuities(owner)
        try validateTail(owner)
    }

    private func validateNested() throws {
        for track in tracks {
            try track.validate()
        }
        for marker in markers {
            try marker.validate()
        }
        for process in capturedProcesses {
            try process.validate()
        }
        for span in inputDevices {
            try span.validate()
        }
        for gap in discontinuities {
            try gap.validate()
        }
    }
}
