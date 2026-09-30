//  TrackAudioSource — порт `GigaAMAudioSource` (модуль gigaam) поверх `AudioTrackReader`
//  (`EngineXPCService`): дорожка записи → PCM 16 кГц моно по диапазону времени в файле (MEE-504, Z6).
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (сторона сервиса)
//
//  Здесь, а не в `EngineXPCService`: таргет `EngineXPCService` не зависит от `GigaAM` в
//  `Packages/Mac/Package.swift` (файл архитектора), а точка входа сервиса зависит от обоих
//  (`project.yml`). Вся логика — в `AudioTrackReader.durationMs(of:)` и
//  `AudioTrackReader.read(_:fromMs:toMs:)`, у которых есть SwiftPM-тесты; этот тип только
//  переадресует вызовы и пишет лог швов.
//
//  ЛОГ ШВОВ (MEE-504, критерий 6 — прослушивание швов вручную). Движок читает дорожку окнами
//  от текущей позиции, и каждое окно, кроме первого, начинается ровно на шве — на месте разреза
//  предыдущего куска (`GigaAMEngine.recognizeChannel`: позиция += длина куска). Поэтому начало
//  каждого чтения с `fromMs > 0` — позиция шва. Пишется в unified log уровнем `notice`
//  (сохраняется на диск без настройки), подсистема `com.andreeyka.meetforme.TranscriptionEngine`,
//  категория `seams`; время — и в файле, и на шкале записи (`+ offsetMs`, инв. 16 C-011):
//
//      log show --last 2h --info --predicate \
//        'subsystem == "com.andreeyka.meetforme.TranscriptionEngine" AND category == "seams"'

import EngineKit
import EngineXPCService
import Foundation
import GigaAM
import os

struct TrackAudioSource: GigaAMAudioSource {

    static let seamLog = Logger(subsystem: "com.andreeyka.meetforme.TranscriptionEngine", category: "seams")

    func durationMs(of audio: AudioRef) throws -> Int {
        let duration = try AudioTrackReader.durationMs(of: audio)
        Self.seamLog.notice("""
            track recording=\(audio.recordingId.uuidString, privacy: .public) \
            channel=\(audio.channel.rawValue, privacy: .public) durationMs=\(duration, privacy: .public) \
            offsetMs=\(audio.offsetMs, privacy: .public)
            """)
        return duration
    }

    func read(_ audio: AudioRef, fromMs: Int, toMs: Int) throws -> [Float] {
        if fromMs > 0 {
            Self.seamLog.notice("""
                seam recording=\(audio.recordingId.uuidString, privacy: .public) \
                channel=\(audio.channel.rawValue, privacy: .public) fileMs=\(fromMs, privacy: .public) \
                recordingMs=\(fromMs + audio.offsetMs, privacy: .public)
                """)
        }
        return try AudioTrackReader.read(audio, fromMs: fromMs, toMs: toMs)
    }
}
