//  AppFacadeImpl — модели чтения (C-016 v9, §1, группа Б плана MEE-410; К5–К9). Разведено
//  из `AppFacadeImpl.swift` по объёму (`file_length`), не по смыслу.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

extension AppFacadeImpl {

    /// К4 (Т+мех): любой метод чтения — `async`, идемпотентен (два подряд вызова без
    /// команд между ними равны). К5 (инв. 4): по возрастанию `start`, при равенстве — по
    /// `meetingId` (сравнением `uuidString` — `UUID` не `Comparable`, тот же приём, что
    /// `SessionMachineOrder.ascending`).
    public func meetings(from: Date, to: Date) async throws -> [MeetingListItem] {
        try await meetingListItems(from: from, to: to)
    }

    /// Общий путь `meetings(from:to:)` и `status().upcoming` (инв. 4: «`AppStatus.upcoming`
    /// отсортирован так же»).
    func meetingListItems(from: Date, to: Date) async throws -> [MeetingListItem] {
        let records: [MeetingRecord]
        do {
            records = try await meetingRepository.meetings(from: from, to: to)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        var items: [MeetingListItem] = []
        items.reserveCapacity(records.count)
        for record in records {
            items.append(try await meetingListItem(for: record))
        }
        return items.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.meetingId.uuidString < rhs.meetingId.uuidString
        }
    }

    private func meetingListItem(for record: MeetingRecord) async throws -> MeetingListItem {
        let event = record.event
        let recordingsForMeeting: [RecordingRecord]
        do {
            recordingsForMeeting = try await recordings.recordings(meetingId: event.id)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        var hasTranscript = false
        for recording in recordingsForMeeting {
            let headers: [TranscriptHeader]
            do {
                headers = try await transcripts.headers(recordingId: recording.manifest.recordingId)
            } catch let error as StorageError {
                throw wrap(error)
            } catch {
                throw wrapUnexpected(error)
            }
            if !headers.isEmpty {
                hasTranscript = true
                break
            }
        }
        return MeetingListItem(
            meetingId: event.id,
            title: event.title,
            start: event.start,
            end: event.end,
            provider: event.conference?.provider,
            status: record.status,
            attendeeCount: event.attendees.count,
            isCancelled: event.isCancelled,
            hasRecording: !recordingsForMeeting.isEmpty,
            hasTranscript: hasTranscript
        )
    }

    /// К6 (инв. 5): `segments` по `startMs`; `speakers` — по убыванию `totalMs`. К7 (инв.
    /// 6): `displayName` синтезируется «Спикер N» (N = `cluster + 1`) при `personId ==
    /// nil`, иначе — имя из `PersonRepository`. К8 (инв. 7, 8): `isUncertain`/
    /// `lowConfidenceWordIndexes` вычисляются по `AttributionThresholds.slice1Defaults` —
    /// источник порогов на вызывающей стороне (C-015 §7 конфигурации) вне зоны групп А/Б
    /// этого PR, так что этот срез берёт умолчания напрямую, а не параметром.
    public func transcript(id: UUID) async throws -> TranscriptView? {
        let transcript: Transcript?
        do {
            transcript = try await transcripts.transcript(id: id)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        guard let transcript else { return nil }
        let headers: [TranscriptHeader]
        do {
            headers = try await transcripts.headers(recordingId: transcript.recordingId)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        guard let header = headers.first(where: { $0.id == id }) else {
            return nil
        }
        return try await buildTranscriptView(id: id, header: header, transcript: transcript)
    }

    public func latestTranscript(recordingId: UUID) async throws -> TranscriptView? {
        let header: TranscriptHeader?
        do {
            header = try await transcripts.latest(recordingId: recordingId)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        guard let header else { return nil }
        let transcript: Transcript?
        do {
            transcript = try await transcripts.transcript(id: header.id)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        guard let transcript else { return nil }
        return try await buildTranscriptView(id: header.id, header: header, transcript: transcript)
    }

    private func buildTranscriptView(
        id: UUID, header: TranscriptHeader, transcript: Transcript
    ) async throws -> TranscriptView {
        let rows: [SegmentRow]
        do {
            rows = try await transcripts.segments(transcriptId: id)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        let rowsByCluster = Dictionary(grouping: rows) { $0.segment.speakerCluster }
        let personIds = Set(rows.compactMap(\.personId))
        let personRecords: [PersonRecord]
        do {
            personRecords = try await persons.persons(ids: Array(personIds))
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        let personById = Dictionary(uniqueKeysWithValues: personRecords.map { ($0.id, $0) })

        let speakerViews = transcript.speakers
            .map { speaker in
                speakerView(for: speaker, rowsOfCluster: rowsByCluster[speaker.cluster] ?? [], personById: personById)
            }
            .sorted { $0.totalMs > $1.totalMs }
        let displayNameByCluster = Dictionary(uniqueKeysWithValues: speakerViews.map { ($0.cluster, $0.displayName) })

        let segmentViews = rows
            .map { row in segmentView(for: row, displayNameByCluster: displayNameByCluster) }
            .sorted { $0.startMs < $1.startMs }

        return TranscriptView(
            header: header, recordingId: transcript.recordingId, speakers: speakerViews, segments: segmentViews
        )
    }

    private func speakerView(
        for speaker: Transcript.Speaker, rowsOfCluster: [SegmentRow], personById: [UUID: PersonRecord]
    ) -> SpeakerView {
        // Атрибуция пишется одним значением на весь кластер разом (C-015 §7,
        // `updateAttribution` по `segmentUpdates`) — любая строка кластера, несущая её,
        // даёт то же значение, что и остальные; берём первую по `startMs` для детерминизма.
        let attributed = rowsOfCluster.sorted { $0.segment.startMs < $1.segment.startMs }.first { $0.personId != nil }
        let personId = attributed?.personId
        let confidence = attributed?.speakerConfidence ?? 0
        // Инв. 6: «Спикер N» только когда personId == nil.
        // СТРОКА: источник AttributionSource для ещё не атрибутированного кластера контракт
        // не называет — `.micChannel` здесь просто нейтральное значение по умолчанию, не
        // утверждение о канале; ни один К группы Б не проверяет его отдельно. Ждёт ответа
        // архитектора, тем же приёмом, что и `AppSettings.slice1Defaults` (MEE-289).
        let source = attributed?.attributionSource ?? .micChannel
        let displayName = personId.flatMap { personById[$0]?.displayName } ?? "Спикер \(speaker.cluster + 1)"
        return SpeakerView(
            cluster: speaker.cluster,
            personId: personId,
            displayName: displayName,
            confidence: confidence,
            source: source,
            isUncertain: confidence < AttributionThresholds.slice1Defaults.confirmedConfidenceMin,
            runnerUpPersonId: nil,
            runnerUpDisplayName: nil,
            totalMs: speaker.totalMs
        )
    }

    private func segmentView(for row: SegmentRow, displayNameByCluster: [Int: String]) -> SegmentView {
        let segment = row.segment
        let lowConfidenceIndexes = segment.words.indices.filter { index in
            guard let confidence = segment.words[index].confidence else { return false }
            return confidence < AttributionThresholds.slice1Defaults.textConfidenceMax
        }
        let displayName = segment.speakerCluster.flatMap { displayNameByCluster[$0] } ?? ""
        return SegmentView(
            segmentId: row.id,
            startMs: segment.startMs,
            endMs: segment.endMs,
            channel: segment.channel,
            cluster: segment.speakerCluster,
            personId: row.personId,
            speakerDisplayName: displayName,
            text: segment.text,
            textOriginal: segment.textOriginal,
            words: segment.words,
            lowConfidenceWordIndexes: lowConfidenceIndexes,
            isUserEdited: row.isUserEdited
        )
    }

    func wrap(_ error: StorageError) -> AppFacadeError {
        let name: String
        switch error {
        case .notFound: name = "notFound"
        case .constraintViolation: name = "constraintViolation"
        case .migrationFailed: name = "migrationFailed"
        case .fileMissing: name = "fileMissing"
        case .dataCorrupted: name = "dataCorrupted"
        case .io: name = "io"
        }
        return .underlying(AppErrorView(
            code: "storage.\(name)", message: String(describing: error), recoverySuggestion: nil, permissionKind: nil
        ))
    }

    // MARK: - Ещё не реализовано этим PR — см. заголовок AppFacadeImpl.swift

    public func meeting(id: UUID) async throws -> MeetingDetail? {
        throw notImplemented("meeting(id:)", group: "В (модели чтения — MeetingDetail)")
    }

    public func search(query: String, limit: Int, offset: Int) async throws -> [SearchHit] {
        throw notImplemented("search(query:limit:offset:)", group: "З (словарь ошибок/поиск)")
    }

    public func jobs(status: JobStatus) async throws -> [Job] {
        throw notImplemented("jobs(status:)", group: "Н (команды обработки)")
    }

    public func settings() async throws -> AppSettings {
        throw notImplemented("settings()", group: "Ж (настройки — ждёт AppSettings.slice1Defaults)")
    }
}
