//  AppFacadeImpl — `meeting(id:)` → `MeetingDetail` (C-016 v11 §1, §4; IR-142 п. 1–2, MEE-455;
//  задачи MEE-449 и MEE-462). Закрывает половину К42 про `RecordingSummary.capturedProcesses`.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ОТКУДА КАКОЕ ПОЛЕ.
//   • `meeting` — `MeetingRepository.meeting(id:)`; строки нет — `nil` (тип ответа `MeetingDetail?`).
//   • `attendees`, `organizer` — `PersonRepository.attendees(meetingId:)`/`organizer(meetingId:)`
//     (C-010 v27, инв. 36): порядок и связь участника без адреса задаёт хранилище, фасад их
//     не пересобирает.
//   • `recordings` — `RecordingRepository.recordings(meetingId:)` в порядке хранилища, по одной
//     `RecordingSummary` на запись. Поля — из манифеста (C-002): `startedAt`/`endedAt`,
//     `markers`, `capturedProcesses` — «объединение за всю запись» (инв. 27) без изменения;
//     `status` — `RecordingRecord.status`; `transcripts` — `TranscriptRepository.headers(recordingId:)`.
//   • `AudioTrackRef.fileURL` — `FileLayout.recordingDirectory(directoryName)` + `Track.fileName`
//     (C-010 §1): `FileLayout` фасад получает в `init` (IR-142 п. 2).
//   • `outputs` — `[]`: «в Срезе 1 всегда пуст» (§1) — резюме не генерируются.
//
//  Отказ хранилища — `.underlying` с `storage.*` (инв. 19), тем же `wrap`, что у прочих чтений.

import Foundation

extension AppFacadeImpl {

    public func meeting(id: UUID) async throws -> MeetingDetail? {
        do {
            guard let record = try await meetingRepository.meeting(id: id) else { return nil }
            let attendees = try await persons.attendees(meetingId: id)
            let organizer = try await persons.organizer(meetingId: id)
            var summaries: [RecordingSummary] = []
            for recording in try await recordings.recordings(meetingId: id) {
                summaries.append(try await recordingSummary(for: recording))
            }
            return MeetingDetail(
                meeting: record, attendees: attendees, organizer: organizer, recordings: summaries, outputs: []
            )
        } catch let error as StorageError {
            throw wrap(error)
        } catch let error as AppFacadeError {
            throw error
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// C-016 v12, инв. 33 (IR-146, MEE-482): записи без встречи. Источник — `RecordingRepository.adHoc()`
    /// (любой `status`, в том числе запись с удалённой встречей); окно — пересечение `[startedAt, endedAt)`
    /// с `[from, to)`, как у `meetings(from:to:)`, у незавершённой записи правая граница открыта;
    /// порядок — `startedAt`, затем `recordingId.uuidString`. Модель строит `recordingSummary(for:)`
    /// — тот же код, что у `MeetingDetail.recordings`. Чтение без побочных эффектов: событий нет.
    public func adHocRecordings(from: Date, to: Date) async throws -> [RecordingSummary] {
        do {
            let inWindow = try await recordings.adHoc().filter { record in
                let manifest = record.manifest
                return manifest.startedAt < to && (manifest.endedAt.map { $0 > from } ?? true)
            }
            let ordered = inWindow.sorted { lhs, rhs in
                if lhs.manifest.startedAt != rhs.manifest.startedAt {
                    return lhs.manifest.startedAt < rhs.manifest.startedAt
                }
                return lhs.manifest.recordingId.uuidString < rhs.manifest.recordingId.uuidString
            }
            var summaries: [RecordingSummary] = []
            summaries.reserveCapacity(ordered.count)
            for record in ordered {
                summaries.append(try await recordingSummary(for: record))
            }
            return summaries
        } catch let error as StorageError {
            throw wrap(error)
        } catch let error as AppFacadeError {
            throw error
        } catch {
            throw wrapUnexpected(error)
        }
    }

    func recordingSummary(for record: RecordingRecord) async throws -> RecordingSummary {
        let manifest = record.manifest
        let directory = fileLayout.recordingDirectory(manifest.directoryName)
        return RecordingSummary(
            recordingId: manifest.recordingId,
            startedAt: manifest.startedAt,
            endedAt: manifest.endedAt,
            status: record.status,
            tracks: manifest.tracks.map {
                AudioTrackRef(channel: $0.channel, fileURL: directory.appendingPathComponent($0.fileName))
            },
            markers: manifest.markers,
            transcripts: try await transcripts.headers(recordingId: manifest.recordingId),
            capturedProcesses: manifest.capturedProcesses
        )
    }
}
