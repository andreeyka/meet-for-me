//  Эталонные тексты `manifest.json` и `transcript.v1.json` — п. 14 перечня.
//
//  Форма — файлы-ресурсы тестового таргета: `Bundle.module` → `Data` → `DomainJSON.decode(_:from:)`.
//  Опора у неё та, что стоит в действующей редакции пункта: эталон обязан меняться вместе с
//  изданием контракта, который он описывает, а каталог `Fixtures/` принадлежит архитектору и
//  приводится им к изданию (`Packages/Core/Package.swift:43`, решение по IR-003). Правка файла
//  там есть `interface-request`, а не коммит, — `Fixtures/README.md` дословно.
//
//  Литеральная форма снята этим же изменением, и ни раньше, ни позже: раньше — эталона не
//  осталось бы вовсе, позже — эталонов было бы два, и они расходились бы молча. Они уже
//  расходились: литерал транскрипта не предъявлял ни `Word.original`, ни `Segment.textOriginal`.
//
//  Смысл пункта от смены носителя не меняется: файл, записанный ДРУГОЙ стороной, читается.
//  Пока эталон писал реализатор, проверка сверяла код с самим собой и была зелена по построению
//  (`docs/module-map.md`, §1).
//
//  Здесь остаются только ожидаемые значения, собранные в коде, — то, с чем сравнивается
//  разобранный эталон, — и признак свойства (з): множества имён ключей по уровням.
//
//  `.copy("Fixtures")` сохраняет структуру каталога, поэтому ресурс адресуется с
//  `subdirectory: "Fixtures"`; без него он не находится. Тем же `.copy` в бандл попадает и
//  `README.md` каталога — он безвреден и никем отсюда не читается.

import Foundation
import DomainCore

enum ReferenceJSON {

    /// Эталон формата — файл каталога `Fixtures/`, адресуемый именем без расширения.
    enum Reference: String, CaseIterable {
        case manifest
        case transcript = "transcript.v1"
    }

    /// Байты эталона, как их положила сборка тестового таргета.
    static func bytes(of reference: Reference) throws -> Data {
        guard let url = Bundle.module.url(forResource: reference.rawValue,
                                          withExtension: "json",
                                          subdirectory: "Fixtures") else {
            throw ReferenceResourceError.missing(reference.rawValue)
        }
        return try Data(contentsOf: url)
    }

    /// Тот же эталон текстом: свойства (в), (д) и (е) — свойства записи, а не значения.
    ///
    /// Перевод failable намеренно: эталон не в UTF-8 — отказ, а не текст с замещающими
    /// символами. Заменяющее чтение прошло бы молча и проверяло бы уже не тот файл.
    static func text(of reference: Reference) throws -> String {
        let data = try bytes(of: reference)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw ReferenceResourceError.notUTF8(reference.rawValue)
        }
        return text
    }

    // MARK: - Признак свойства (з): имена ключей по уровням

    /// Имена ключей JSON по уровням: путь без индексов массивов → объединение имён на нём.
    ///
    /// Ключ засчитывается ПРЕДЪЯВЛЕННЫМ, а не заполненным: `"original": null` — предъявление.
    /// Свойство (з) говорит про эталон, «молчащий о поле», а явный `null` — не молчание, и
    /// проверка непустого значения покраснела бы на `Word.original` и `Segment.textOriginal`.
    static func keyNamesByLevel(inJSON data: Data) throws -> [String: Set<String>] {
        var table: [String: Set<String>] = [:]
        collect(try JSONSerialization.jsonObject(with: data), at: "", into: &table)
        return table
    }

    private static func collect(_ value: Any, at path: String, into table: inout [String: Set<String>]) {
        if let object = value as? [String: Any] {
            table[path, default: []].formUnion(object.keys)
            for (name, child) in object {
                collect(child, at: path.isEmpty ? name : "\(path).\(name)", into: &table)
            }
        } else if let array = value as? [Any] {
            for element in array {
                collect(element, at: path, into: &table)
            }
        }
    }

    // MARK: - Значения, собранные в коде: с ними сравнивается разобранный эталон

    static func expectedManifest() throws -> RecordingManifest {
        let recordingId = try makeUUID("3F2504E0-4F89-41D3-9A0C-0305E82C3301")
        return try RecordingManifest(
            recordingId: recordingId,
            meetingId: nil,
            directoryName: recordingId.uuidString,
            startedAt: date(milliseconds: 1_789_119_000_000),
            endedAt: date(milliseconds: 1_789_122_680_500),
            tracks: [
                try RecordingManifest.Track(channel: .mic, fileName: "audio-mic.m4a",
                                            sampleRate: 48_000, channelCount: 1, format: "aac-m4a"),
                try RecordingManifest.Track(channel: .system, fileName: "audio-system.m4a",
                                            sampleRate: 48_000, channelCount: 2, format: "aac-m4a")
            ],
            markers: [
                try RecordingManifest.Marker(kind: .sleep, atMs: 1_800_000, detail: nil),
                try RecordingManifest.Marker(kind: .discontinuity, atMs: 1_800_000,
                                             detail: "aggregate device rebuilt"),
                try RecordingManifest.Marker(kind: .wake, atMs: 1_802_000, detail: nil),
                try RecordingManifest.Marker(kind: .deviceChanged, atMs: 2_400_000,
                                             detail: "BuiltInMicrophoneDevice -> A1B2C3-airpods")
            ],
            capturedProcesses: [
                try RecordingManifest.CapturedProcess(pid: 4_821, bundleId: "us.zoom.xos",
                                                      executableName: "zoom.us")
            ],
            captureGroupKey: "bundle:us.zoom.xos",
            inputDevices: [
                try RecordingManifest.InputDeviceSpan(atMs: 0, present: true,
                                                      name: "MacBook Pro Microphone",
                                                      uid: "BuiltInMicrophoneDevice"),
                try RecordingManifest.InputDeviceSpan(atMs: 2_400_000, present: true,
                                                      name: "AirPods Pro", uid: "A1B2C3-airpods")
            ],
            discontinuities: [
                try RecordingManifest.Discontinuity(atMs: 1_800_000, gapMs: 2_000,
                                                    scaleErrorMs: 150, reason: .rebuild)
            ],
            isFinalized: true
        )
    }

    static func expectedTranscript() throws -> Transcript {
        try Transcript(
            recordingId: try makeUUID("3F2504E0-4F89-41D3-9A0C-0305E82C3301"),
            language: "ru",
            engine: "gigaam-sherpa-onnx",
            modelVersion: "v3.0.1",
            createdAt: date(milliseconds: 1_789_122_912_250),
            segments: try expectedSegments(),
            speakers: [
                try Transcript.Speaker(cluster: 0, embedding: [0.0125, -0.5, 0.75],
                                       embeddingModelVersion: "wespeaker-v2", totalMs: 3_000),
                try Transcript.Speaker(cluster: 1, embedding: nil,
                                       embeddingModelVersion: nil, totalMs: 0)
            ]
        )
    }

    /// Сегменты эталона транскрипта вынесены отдельно: тело `expectedTranscript()` иначе
    /// перерастает предел длины, а составляют его одни литералы.
    private static func expectedSegments() throws -> [Transcript.Segment] {
        [
            try Transcript.Segment(
                startMs: 1_200, endMs: 3_400, channel: .mic, speakerCluster: nil,
                text: "Привет, начнём.", textOriginal: nil, textConfidence: 0.88,
                words: [
                    try Transcript.Word(startMs: 1_200, endMs: 1_900, text: "Привет,",
                                        confidence: 0.94, original: nil),
                    try Transcript.Word(startMs: 1_900, endMs: 2_600, text: "начнём.",
                                        confidence: 0.88, original: nil)
                ]
            ),
            try Transcript.Segment(
                startMs: 3_000, endMs: 6_000, channel: .system, speakerCluster: 0,
                text: "Да, я готов.", textOriginal: nil, textConfidence: 0.7, words: []
            ),
            try Transcript.Segment(
                startMs: 6_100, endMs: 9_000, channel: .system, speakerCluster: nil,
                text: "   ", textOriginal: nil, textConfidence: nil, words: []
            )
        ]
    }

    // MARK: - Значения со всеми непустыми необязательными полями — ожидаемая сторона (з)

    /// Значение, у которого непусто КАЖДОЕ необязательное поле: п. 7 требует кодировать `nil`
    /// отсутствием ключа, значит у такого значения появляется ровно каждый объявленный ключ и
    /// ни одного лишнего. Этим оно и служит признаком полноты вместо списка имён.
    ///
    /// `CodingKeys` для этого не годятся: они `internal`, а импорт идёт без `@testable` (п. 97).
    /// `Mirror` не годится тоже: он даёт снимок значения, а не объявление типа.
    static func manifestWithEveryFieldFilled() throws -> RecordingManifest {
        let recordingId = try makeUUID("3F2504E0-4F89-41D3-9A0C-0305E82C3301")
        return try RecordingManifest(
            recordingId: recordingId,
            meetingId: try makeUUID("11111111-1111-4111-8111-111111111111"),
            directoryName: recordingId.uuidString,
            startedAt: date(milliseconds: 0),
            endedAt: date(milliseconds: 1_000),
            tracks: [
                try RecordingManifest.Track(channel: .mic, fileName: "audio-mic.m4a",
                                            sampleRate: 48_000, channelCount: 1, format: "aac-m4a")
            ],
            markers: [
                try RecordingManifest.Marker(kind: .discontinuity, atMs: 0, detail: "подробность")
            ],
            capturedProcesses: [
                try RecordingManifest.CapturedProcess(pid: 1, bundleId: "us.zoom.xos",
                                                      executableName: "zoom.us")
            ],
            captureGroupKey: "bundle:us.zoom.xos",
            inputDevices: [
                try RecordingManifest.InputDeviceSpan(atMs: 0, present: true, name: "Микрофон",
                                                      uid: "BuiltInMicrophoneDevice")
            ],
            discontinuities: [
                try RecordingManifest.Discontinuity(atMs: 0, gapMs: 0, scaleErrorMs: 0,
                                                    reason: .rebuild)
            ],
            isFinalized: true
        )
    }

    /// То же для транскрипта. Сегмент системного канала с кластером взят потому, что инвариант 5
    /// запрещает кластер микрофонному каналу: непустым `speakerCluster` бывает только системный.
    static func transcriptWithEveryFieldFilled() throws -> Transcript {
        try Transcript(
            recordingId: try makeUUID("3F2504E0-4F89-41D3-9A0C-0305E82C3301"),
            language: "ru",
            engine: "gigaam-sherpa-onnx",
            modelVersion: "v3.0.1",
            createdAt: date(milliseconds: 0),
            segments: [
                try Transcript.Segment(
                    startMs: 0, endMs: 1_000, channel: .system, speakerCluster: 0,
                    text: "Андрей", textOriginal: "андрей", textConfidence: 0.5,
                    words: [
                        try Transcript.Word(startMs: 0, endMs: 1_000, text: "Андрей",
                                            confidence: 0.5, original: "андрей")
                    ]
                )
            ],
            speakers: [
                try Transcript.Speaker(cluster: 0, embedding: [0.5],
                                       embeddingModelVersion: "wespeaker-v2", totalMs: 1_000)
            ]
        )
    }
}

/// Ресурс, объявленный сборкой, но не найденный в бандле, — отказ, а не пропуск.
enum ReferenceResourceError: Error {
    case missing(String)
    case notUTF8(String)
}
