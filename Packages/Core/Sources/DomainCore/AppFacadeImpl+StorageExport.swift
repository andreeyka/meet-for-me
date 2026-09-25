//  AppFacadeImpl — хранение и экспорт (C-016 v10, группа П плана MEE-410; К41, MEE-441).
//  Разведено из `AppFacadeImpl.swift` по объёму (`file_length`), не по смыслу.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  `deleteRecording`/`deleteMeeting` — К41, действующий текст перечня MEE-401: «пробрасывают
//  вызов в storage (C-010) без дополнительной логики: счётчик обращений к репозиторию — ровно
//  один на вызов». Ни файлов (`RecordingRepository.delete(recordingId:deleteFiles:)` сама
//  решает, что делать с `deleteFiles`), ни каскада (`MeetingRepository.delete(meetingIds:)`
//  сама уносит recordings/meeting_outputs — см. `InMemoryRepositories.swift`, `attachCascade`)
//  этот метод не трогает второй раз.
//
//  `export` — инв. 17 дословно и целиком: «`export` создаёт файл или каталог внутри
//  переданной `directory` и возвращает путь к нему; за пределы `directory` не пишет ничего».
//  Больше контракт не говорит об этом методе ничего — ни слова о содержимом/формате файла
//  (не про К41: инв. 17 — единственный текст источника на весь метод, сверено C-016 §4
//  целиком). Содержимое каждого формата ниже поэтому не предмет теста плана (К41 проверяет
//  только расположение), но не пустышка — сериализует то же, что уже читают модели чтения
//  (сегменты, `startMs`/`endMs`/`text`), не изобретая новых полей.

import Foundation

extension AppFacadeImpl {

    public func deleteRecording(recordingId: UUID, deleteFiles: Bool) async throws {
        do {
            try await recordings.delete(recordingId: recordingId, deleteFiles: deleteFiles)
            publish(.meetingsChanged)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    public func deleteMeeting(meetingId: UUID) async throws {
        do {
            try await meetingRepository.delete(meetingIds: [meetingId])
            publish(.meetingsChanged)
            publish(.statusChanged(await status()))
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    public func export(meetingId: UUID, format: ExportFormat, to directory: URL) async throws -> URL {
        let meeting: MeetingRecord?
        do {
            meeting = try await meetingRepository.meeting(id: meetingId)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        guard let meeting else {
            throw AppFacadeError.notFound(entity: "Meeting", id: meetingId.uuidString)
        }
        do {
            let lines = try await exportLines(meetingId: meetingId)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try write(title: meeting.event.title, lines: lines, format: format, to: directory)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    private struct ExportLine {
        let speakerLabel: String
        let startMs: Int
        let endMs: Int
        let text: String
    }

    /// Один список строк по всем записям встречи, каждая — последняя транскрипция своей
    /// записи (`TranscriptRepository.latest(recordingId:)`), сегменты — по `startMs` (тот же
    /// порядок, что К6 у моделей чтения). Без записи транскрипции у записи — просто нет строк
    /// от неё, не отказ.
    private func exportLines(meetingId: UUID) async throws -> [ExportLine] {
        let meetingRecordings = try await recordings.recordings(meetingId: meetingId)
        var lines: [ExportLine] = []
        for recording in meetingRecordings {
            guard let header = try await transcripts.latest(recordingId: recording.manifest.recordingId) else {
                continue
            }
            let segments = try await transcripts.segments(transcriptId: header.id)
            for row in segments.sorted(by: { $0.segment.startMs < $1.segment.startMs }) {
                let label = row.segment.speakerCluster.map { "Спикер \($0)" } ?? "Спикер"
                lines.append(ExportLine(
                    speakerLabel: label, startMs: row.segment.startMs, endMs: row.segment.endMs,
                    text: row.segment.text
                ))
            }
        }
        return lines
    }

    private func write(title: String, lines: [ExportLine], format: ExportFormat, to directory: URL) throws -> URL {
        switch format {
        case .markdown:
            return try writeFile(markdown(title: title, lines: lines), name: "export.md", to: directory)
        case .json:
            return try writeFile(json(lines: lines), name: "export.json", to: directory)
        case .srt:
            return try writeFile(subtitles(lines: lines, vtt: false), name: "export.srt", to: directory)
        case .vtt:
            return try writeFile(subtitles(lines: lines, vtt: true), name: "export.vtt", to: directory)
        case .bundle:
            let bundleDir = directory.appendingPathComponent("export", isDirectory: true)
            try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
            _ = try writeFile(markdown(title: title, lines: lines), name: "export.md", to: bundleDir)
            _ = try writeFile(json(lines: lines), name: "export.json", to: bundleDir)
            return bundleDir
        }
    }

    private func writeFile(_ content: Data, name: String, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try content.write(to: url, options: .atomic)
        return url
    }

    private func markdown(title: String, lines: [ExportLine]) -> Data {
        var text = "# \(title)\n\n"
        for line in lines {
            text += "**\(line.speakerLabel)**: \(line.text)\n\n"
        }
        return Data(text.utf8)
    }

    private func json(lines: [ExportLine]) -> Data {
        struct Row: Encodable {
            let speaker: String
            let startMs: Int
            let endMs: Int
            let text: String
        }
        let rows = lines.map { Row(speaker: $0.speakerLabel, startMs: $0.startMs, endMs: $0.endMs, text: $0.text) }
        return (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
    }

    private func subtitles(lines: [ExportLine], vtt: Bool) -> Data {
        var text = vtt ? "WEBVTT\n\n" : ""
        for (index, line) in lines.enumerated() {
            if !vtt { text += "\(index + 1)\n" }
            text += "\(subtitleTimestamp(line.startMs, vtt: vtt)) --> \(subtitleTimestamp(line.endMs, vtt: vtt))\n"
            text += "\(line.speakerLabel): \(line.text)\n\n"
        }
        return Data(text.utf8)
    }

    /// Без `String(format:)` — `%@` в нём не гарантирован swift-corelibs-foundation на
    /// Linux (`Core (Linux)`, единственная работа CI, что собирает этот таргет).
    private func subtitleTimestamp(_ ms: Int, vtt: Bool) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let millis = ms % 1000
        let separator = vtt ? "." : ","
        return "\(pad(hours)):\(pad(minutes)):\(pad(seconds))\(separator)\(pad(millis, width: 3))"
    }

    private func pad(_ value: Int, width: Int = 2) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
