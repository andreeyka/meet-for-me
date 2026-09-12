//  Собственные инварианты RecordingManifest — ступень (б), в порядке номеров.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Преобразование в `Int` в инвариантах 11 и 18 безопасно не по величине реальных записей,
//  а по порядку ступеней: обе даты уже проверены ступенью (в) и лежат в 0001…9999, поэтому
//  |endedAt − startedAt| < 3,16e11 с, после ×1000 меньше 3,2e14 — на четыре порядка ниже Int64.max.

import Foundation

extension RecordingManifest {

    /// Промежуточная величина инвариантов 11 и 18. Полем и частью API она не является.
    var durationMilliseconds: Int? {
        guard let endedAt else { return nil }
        return Int((endedAt.timeIntervalSince(startedAt) * 1000).rounded())
    }

    /// Инварианты 1, 2, 4, 7.
    func validateShape(_ owner: DomainOwner) throws {
        try owner.check(schemaVersion == RecordingManifest.currentSchemaVersion, 1, "schemaVersion",
                        "файл схемы \(schemaVersion), этот код принимает "
                        + "\(RecordingManifest.currentSchemaVersion)")
        try owner.check(!tracks.isEmpty, 2, "tracks", "tracks пуст")
        var channels = Set<Channel>()
        for track in tracks where !channels.insert(track.channel).inserted {
            throw owner.fail(2, "tracks", "два трека канала \(track.channel.rawValue)")
        }
        var names = Set<String>()
        for track in tracks where !names.insert(track.fileName).inserted {
            throw owner.fail(4, "tracks", "имя файла \(track.fileName) встречается дважды")
        }
        try owner.check(directoryName == recordingId.uuidString, 7, "directoryName",
                        "каталог \(directoryName) не равен \(recordingId.uuidString)")
    }

    /// Инварианты 8, 9, 10.
    func validateOrdering(_ owner: DomainOwner) throws {
        for position in markers.indices.dropFirst()
        where markers[position].atMs < markers[position - 1].atMs {
            throw owner.fail(8, "markers[\(position)].atMs", "маркеры не отсортированы по неубыванию")
        }
        if let first = inputDevices.first {
            try owner.check(first.atMs == 0, 9, "inputDevices[0].atMs",
                            "первый спан начинается не с нуля")
        }
        for position in inputDevices.indices.dropFirst()
        where inputDevices[position].atMs <= inputDevices[position - 1].atMs {
            throw owner.fail(9, "inputDevices[\(position)].atMs", "спаны не возрастают строго")
        }
        try validateDeviceCorrespondence(owner)
    }

    /// Инвариант 10: обход коллекций в порядке объявления полей — сперва `markers`.
    private func validateDeviceCorrespondence(_ owner: DomainOwner) throws {
        let spanTimes = Set(inputDevices.map(\.atMs))
        for (position, marker) in markers.enumerated()
        where marker.kind == .deviceChanged && !spanTimes.contains(marker.atMs) {
            throw owner.fail(10, "markers[\(position)].atMs", "у маркера deviceChanged нет парного спана")
        }
        var changeTimes = Set<Int>()
        for marker in markers where marker.kind == .deviceChanged {
            changeTimes.insert(marker.atMs)
        }
        for (position, span) in inputDevices.enumerated()
        where span.atMs > 0 && !changeTimes.contains(span.atMs) {
            throw owner.fail(10, "inputDevices[\(position)].atMs", "у спана нет парного маркера")
        }
    }

    /// Инварианты 11, 12, 13.
    func validateBounds(_ owner: DomainOwner) throws {
        if let limit = durationMilliseconds {
            for (position, marker) in markers.enumerated() where marker.atMs > limit {
                throw owner.fail(11, "markers[\(position)].atMs", "atMs больше длительности записи")
            }
            for (position, span) in inputDevices.enumerated() where span.atMs > limit {
                throw owner.fail(11, "inputDevices[\(position)].atMs", "atMs больше длительности записи")
            }
        }
        if let endedAt {
            try owner.check(endedAt >= startedAt, 12, "endedAt", "endedAt раньше startedAt")
        }
        guard isFinalized else { return }
        try owner.check(endedAt != nil, 13, "endedAt", "финализированная запись без endedAt")
        for (position, track) in tracks.enumerated() where track.format != "aac-m4a" {
            throw owner.fail(13, "tracks[\(position)].format", "финализация при формате \(track.format)")
        }
    }

    /// Инварианты 14 и 15.
    func validateDiscontinuities(_ owner: DomainOwner) throws {
        for position in discontinuities.indices.dropFirst()
        where discontinuities[position].atMs < discontinuities[position - 1].atMs {
            throw owner.fail(14, "discontinuities[\(position)].atMs",
                             "разрывы не отсортированы по неубыванию")
        }
        var gapCounts: [Int: Int] = [:]
        for gap in discontinuities {
            gapCounts[gap.atMs, default: 0] += 1
        }
        var markerCounts: [Int: Int] = [:]
        for marker in markers where marker.kind == .discontinuity {
            markerCounts[marker.atMs, default: 0] += 1
        }
        for (position, marker) in markers.enumerated()
        where marker.kind == .discontinuity && gapCounts[marker.atMs] != markerCounts[marker.atMs] {
            throw owner.fail(15, "markers[\(position)].atMs", "кратность разрывов не равна кратности маркеров")
        }
        for (position, gap) in discontinuities.enumerated()
        where markerCounts[gap.atMs] != gapCounts[gap.atMs] {
            throw owner.fail(15, "discontinuities[\(position)].atMs",
                             "кратность маркеров не равна кратности разрывов")
        }
    }

    /// Инварианты 16 и 18.
    func validateTail(_ owner: DomainOwner) throws {
        try owner.check(captureGroupKey != "", 16, "captureGroupKey", "пустая строка не значение")
        guard let limit = durationMilliseconds else { return }
        for (position, gap) in discontinuities.enumerated() where gap.atMs > limit {
            throw owner.fail(18, "discontinuities[\(position)].atMs", "atMs больше длительности записи")
        }
    }
}
