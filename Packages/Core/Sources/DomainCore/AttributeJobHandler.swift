//  AttributeJobHandler — обработчик задачи `.attribute` (C-015 §7 v10, C-013 v13),
//  MEE-415. Строит `AttributionInput` из репозиториев `domain-core`, зовёт
//  `AttributionPort.attribute`, применяет `AttributionResult` и отображает отказы в
//  `JobOutcome` дословно по §7.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  МЕСТО — здесь, не в `attribution`: C-013, раздел «Ломающие изменения v11 против v10»
//  (IR-080, MEE-175), решил это для домена целиком, `docs/module-map.md` подтверждает.
//  `TranscribeJobHandler.swift` — тот же приём для задачи `.transcribe`, отсюда и форма
//  этого файла: `struct`, а не `class`, одна зависимость на порт плюс репозитории,
//  `guard case` на payload первой строкой `run(_:progress:)`.
//
//  СТРОКА (временно, до ответа РП на блокер MEE-415, Linear-комментарий 01:48 UTC):
//  §7 называет единственный источник `voiceProfilesEnabled` — `AppFacade.settings()`
//  (C-016). `AppFacade`/`AppFacadeError`/`AppErrorView` не объявлены в дереве ни строкой
//  (проверено `grep` по всему `*.swift`; тот же блокер уже назвал МЕЕ-396 §0.4/§8
//  независимо, днём раньше). Объявление типов чужого контракта — решение архитектора,
//  не этой задачи, поэтому источник здесь — простое замыкание, а не тип с именем
//  `AppFacade`, чтобы не столкнуться с будущим объявлением. К33 (сама передача флага и
//  гейт `profiles`) построен и проверен; К49 (`AppFacadeError` → `JobOutcome` по случаю,
//  `settingsUnreadable`/`underlying`) НЕ реализован — любая ошибка замыкания сегодня
//  уходит через общий `catch` ниже как `.permanentFailure`, что вернее контракта не
//  проверяет: замену на настоящий `AppFacade.settings()` и точную проверку К49 — отдельным
//  коммитом после решения РП.
//
//  ПОРЯДОК ПОСТРОЕНИЯ ВХОДА здесь не совпадает построчно с порядком перечисления полей
//  в §7: `embeddingModelVersion` вычислен раньше `profiles` (а не позже, как в тексте),
//  потому что `profiles` — это `SpeakerProfileRepository.profiles(personIds:modelVersion:)`,
//  и `modelVersion` ему взять неоткуда, кроме уже вычисленного `embeddingModelVersion`;
//  ранний выход при испорченной версии (абзац «embeddingModelVersion» §7) при этом
//  избавляет от бессмысленного чтения профилей на входе, который и так завершится
//  `permanentFailure`. Контракт описывает эффекты, не порядок вызовов, — перестановка
//  внутри одного метода без внешне наблюдаемой разницы не решение, которое передают
//  архитектору.

import Foundation

public struct AttributeJobHandler: JobHandler {
    public let type: JobType = .attribute

    private let port: AttributionPort
    private let transcripts: TranscriptRepository
    private let meetings: MeetingRepository
    private let persons: PersonRepository
    private let speakerProfiles: SpeakerProfileRepository
    private let voiceProfilesEnabled: @Sendable () async throws -> Bool

    public init(
        port: AttributionPort,
        transcripts: TranscriptRepository,
        meetings: MeetingRepository,
        persons: PersonRepository,
        speakerProfiles: SpeakerProfileRepository,
        voiceProfilesEnabled: @Sendable @escaping () async throws -> Bool
    ) {
        self.port = port
        self.transcripts = transcripts
        self.meetings = meetings
        self.persons = persons
        self.speakerProfiles = speakerProfiles
        self.voiceProfilesEnabled = voiceProfilesEnabled
    }

    public func run(
        _ job: Job,
        progress: @Sendable @escaping (Double) -> Void
    ) async -> JobOutcome {
        guard case .attribute(let transcriptId, let meetingId) = job.payload else {
            return .permanentFailure(error: "AttributeJobHandler получил job.payload не .attribute")
        }
        do {
            let input = try await buildInput(transcriptId: transcriptId, meetingId: meetingId)
            let result = try await port.attribute(input, thresholds: .slice1Defaults)
            try await apply(result, transcriptId: transcriptId)
            return .success
        } catch let failure as InputBuildFailure {
            return .permanentFailure(error: failure.message)
        } catch let error as AttributionError {
            // §7 дословно: все шесть случаев — данные или согласованность, не сеть и не
            // диск, повтор с тем же входом дал бы тот же результат. `.retry` не заведён.
            return .permanentFailure(error: "\(error)")
        } catch let error as StorageError {
            return Self.outcome(for: error)
        } catch {
            return .permanentFailure(error: "\(error)")
        }
    }

    /// Ранний выход построения входа — не `StorageError` и не `AttributionError`:
    /// обработчик не строит `AttributionInput` и не вызывает порт вовсе (§7 дословно).
    private enum InputBuildFailure: Error {
        case transcriptNotFound(UUID)
        case embeddingModelVersionMissing(transcriptId: UUID)

        var message: String {
            switch self {
            case .transcriptNotFound(let id):
                return "AttributeJobHandler: транскрипт \(id) не найден"
            case .embeddingModelVersionMissing(let id):
                return "AttributeJobHandler: транскрипт \(id) несёт спикеров без единой версии эмбеддинга"
            }
        }
    }

    /// §7 «Отказ репозитория»: пять случаев — тем же доводом, что и `AttributionError`,
    /// повтор с той же строкой базы даёт тот же результат; только `io` — переходный
    /// случай (диск, конкурентная блокировка), `.retry(after: 30, error:)` — тот же
    /// первый шаг лестницы по умолчанию (C-013 §5, `30 · 2^0`), назван явно.
    private static func outcome(for error: StorageError) -> JobOutcome {
        switch error {
        case .io:
            return .retry(after: 30, error: "\(error)")
        case .notFound, .constraintViolation, .migrationFailed, .fileMissing, .dataCorrupted:
            return .permanentFailure(error: "\(error)")
        }
    }

    // MARK: - Построение AttributionInput (§7)

    private func buildInput(transcriptId: UUID, meetingId: UUID?) async throws -> AttributionInput {
        guard let transcript = try await transcripts.transcript(id: transcriptId) else {
            throw InputBuildFailure.transcriptNotFound(transcriptId)
        }
        let segmentRows = try await transcripts.segments(transcriptId: transcriptId)
        let segmentIds = segmentRows.map(\.id)
        let userEditedSegmentIds = segmentRows.filter(\.isUserEdited).map(\.id)
        let embeddingModelVersion = try Self.embeddingModelVersion(transcript: transcript, transcriptId: transcriptId)

        let attendees = try await resolvedAttendees(meetingId: meetingId)
        let me = try await persons.me()
        var nameFormPersonIds = Set(attendees.map(\.id))
        if let me { nameFormPersonIds.insert(me.id) }
        let nameForms = try await persons.nameForms(personIds: Array(nameFormPersonIds))

        let voiceEnabled = try await voiceProfilesEnabled()
        let profiles: [SpeakerProfile]
        if voiceEnabled {
            profiles = try await speakerProfiles.profiles(
                personIds: Array(nameFormPersonIds), modelVersion: embeddingModelVersion
            )
        } else {
            profiles = []
        }

        return AttributionInput(
            transcriptId: transcriptId, transcript: transcript, segmentIds: segmentIds,
            meetingId: meetingId, attendees: attendees, me: me, nameForms: nameForms,
            profiles: profiles, voiceProfilesEnabled: voiceEnabled,
            embeddingModelVersion: embeddingModelVersion, userEditedSegmentIds: userEditedSegmentIds
        )
    }

    /// §7 «attendees»: пусто и для `meetingId == nil` (ad-hoc созвон), и для встречи,
    /// удалённой между постановкой задачи и её выполнением, — тем же путём; адреса, не
    /// разрешившиеся в `PersonRecord`, из списка выпадают молча.
    private func resolvedAttendees(meetingId: UUID?) async throws -> [PersonRecord] {
        guard let meetingId, let meeting = try await meetings.meeting(id: meetingId) else {
            return []
        }
        var resolved: [PersonRecord] = []
        for attendee in meeting.event.attendees {
            guard let email = attendee.person.email,
                  let person = try await persons.person(email: email) else { continue }
            resolved.append(person)
        }
        return resolved
    }

    /// §7 «embeddingModelVersion»: первая непустая версия среди `transcript.speakers`;
    /// пустой `speakers` — штатный вход (запись только с микрофона, IR-128), версия — "".
    /// Спикеры есть, а версии нет ни у одного — испорченный вход, ранний `permanentFailure`.
    private static func embeddingModelVersion(transcript: Transcript, transcriptId: UUID) throws -> String {
        guard !transcript.speakers.isEmpty else { return "" }
        guard let version = transcript.speakers.compactMap(\.embeddingModelVersion).first else {
            throw InputBuildFailure.embeddingModelVersionMissing(transcriptId: transcriptId)
        }
        return version
    }

    // MARK: - Применение AttributionResult (§7 «Применение»)

    private func apply(_ result: AttributionResult, transcriptId: UUID) async throws {
        if !result.segmentUpdates.isEmpty {
            try await transcripts.updateAttribution(result.segmentUpdates)
        }
        for update in result.profileUpdates {
            try await speakerProfiles.upsert(SpeakerProfile(
                personId: update.personId, embedding: update.embedding,
                modelVersion: update.modelVersion, sampleCount: update.sampleCount, updatedAt: Date()
            ))
        }
        try await applyTextCorrections(result.textCorrections, transcriptId: transcriptId)
    }

    /// §7: по одному вызову `applyTextCorrections` на сегмент, у которого правки этого
    /// сегмента непусты — не один вызов на весь результат. `text` строит обработчик,
    /// заменяя слова по `wordIndex`; способ склейки слов в строку — не предмет контракта
    /// и не проверяется инвариантом 32 (C-010): решение реализации — соединение пробелом.
    private func applyTextCorrections(_ corrections: [TextCorrection], transcriptId: UUID) async throws {
        guard !corrections.isEmpty else { return }
        let bySegment = Dictionary(grouping: corrections, by: \.segmentId)
        let rows = try await transcripts.segments(transcriptId: transcriptId)
        let wordsBySegment = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.segment.words) })
        for (segmentId, segmentCorrections) in bySegment {
            let words = wordsBySegment[segmentId] ?? []
            let text = Self.correctedText(words: words, corrections: segmentCorrections)
            try await transcripts.applyTextCorrections(
                segmentId: segmentId, text: text, corrections: segmentCorrections
            )
        }
    }

    private static func correctedText(words: [Transcript.Word], corrections: [TextCorrection]) -> String {
        let replacementByIndex = Dictionary(uniqueKeysWithValues: corrections.map { ($0.wordIndex, $0.replacement) })
        return words.enumerated()
            .map { index, word in replacementByIndex[index] ?? word.text }
            .joined(separator: " ")
    }
}
