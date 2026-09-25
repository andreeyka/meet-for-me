//  AttributionSupport — общее построение `AttributionInput` (C-015 §7) и применение
//  `AttributionResult` (§7 «Применение»). Разведено из `AttributeJobHandler` (MEE-415) сюда,
//  чтобы группа Д плана MEE-410 (`AppFacadeImpl.assignSpeaker`/`clearSpeaker`/
//  `createPersonAndAssign`, MEE-420) не дублировала ~80 строк той же логики построения
//  входа и применения результата — риск разойтись в двух местах хуже лишней абстракции
//  внутри одного модуля.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

enum AttributionSupport {

    /// Ранний выход построения входа — не `StorageError` и не `AttributionError`: вызывающая
    /// сторона порт вовсе не зовёт (то же деление, что уже было у `AttributeJobHandler`).
    enum InputBuildFailure: Error {
        case transcriptNotFound(UUID)
        case embeddingModelVersionMissing(transcriptId: UUID)

        var message: String {
            switch self {
            case .transcriptNotFound(let id):
                return "AttributionSupport: транскрипт \(id) не найден"
            case .embeddingModelVersionMissing(let id):
                return "AttributionSupport: транскрипт \(id) несёт спикеров без единой версии эмбеддинга"
            }
        }
    }

    /// Репозитории, нужные построению `AttributionInput` — сгруппированы одним значением,
    /// чтобы не упереться в `function_parameter_count` (порог 5/8): у `buildInput` и так
    /// пять содержательных параметров сверх этого, не считая репозиториев.
    struct Repositories {
        let transcripts: TranscriptRepository
        let meetings: MeetingRepository
        let persons: PersonRepository
        let speakerProfiles: SpeakerProfileRepository

        init(
            transcripts: TranscriptRepository, meetings: MeetingRepository,
            persons: PersonRepository, speakerProfiles: SpeakerProfileRepository
        ) {
            self.transcripts = transcripts
            self.meetings = meetings
            self.persons = persons
            self.speakerProfiles = speakerProfiles
        }
    }

    /// Построение `AttributionInput` (C-015 §7). `excludingClusterFromUserEdited` — К50
    /// плана MEE-410 (дельта Щ перечня MEE-401): при ручном назначении (`confirm`/`reject`
    /// для конкретного `cluster`) сегменты ЭТОГО кластера исключены из `userEditedSegmentIds`,
    /// даже если уже помечены `is_user_edited = 1`, — иначе `AttributionPort`, честно
    /// соблюдающий инвариант 8 C-010 (защита уже помеченных строк от повторной атрибуции),
    /// отфильтровал бы собственный ответ на команду переназначения этого же кластера прежде,
    /// чем она успеет что-то сделать. Автоматическая атрибуция (`AttributeJobHandler`)
    /// передаёт `nil` — там нет одного выделенного кластера, который сейчас правят.
    static func buildInput(
        transcriptId: UUID,
        meetingId: UUID?,
        excludingClusterFromUserEdited excludedCluster: Int?,
        repositories: Repositories,
        voiceProfilesEnabled: Bool
    ) async throws -> AttributionInput {
        guard let transcript = try await repositories.transcripts.transcript(id: transcriptId) else {
            throw InputBuildFailure.transcriptNotFound(transcriptId)
        }
        let segmentRows = try await repositories.transcripts.segments(transcriptId: transcriptId)
        let segmentIds = segmentRows.map(\.id)
        let userEditedSegmentIds = segmentRows
            .filter { $0.isUserEdited && $0.segment.speakerCluster != excludedCluster }
            .map(\.id)
        let embeddingModelVersion = try embeddingModelVersion(transcript: transcript, transcriptId: transcriptId)

        let attendees = try await resolvedAttendees(meetingId: meetingId, repositories: repositories)
        let me = try await repositories.persons.me()
        var nameFormPersonIds = Set(attendees.map(\.id))
        if let me { nameFormPersonIds.insert(me.id) }
        let nameForms = try await repositories.persons.nameForms(personIds: Array(nameFormPersonIds))

        let profiles: [SpeakerProfile]
        if voiceProfilesEnabled {
            profiles = try await repositories.speakerProfiles.profiles(
                personIds: Array(nameFormPersonIds), modelVersion: embeddingModelVersion
            )
        } else {
            profiles = []
        }

        return AttributionInput(
            transcriptId: transcriptId, transcript: transcript, segmentIds: segmentIds,
            meetingId: meetingId, attendees: attendees, me: me, nameForms: nameForms,
            profiles: profiles, voiceProfilesEnabled: voiceProfilesEnabled,
            embeddingModelVersion: embeddingModelVersion, userEditedSegmentIds: userEditedSegmentIds
        )
    }

    /// §7 «attendees»: пусто и для `meetingId == nil` (ad-hoc созвон), и для встречи,
    /// удалённой между постановкой задачи и её выполнением, — тем же путём; адреса, не
    /// разрешившиеся в `PersonRecord`, из списка выпадают молча.
    private static func resolvedAttendees(
        meetingId: UUID?, repositories: Repositories
    ) async throws -> [PersonRecord] {
        guard let meetingId, let meeting = try await repositories.meetings.meeting(id: meetingId) else {
            return []
        }
        var resolved: [PersonRecord] = []
        for attendee in meeting.event.attendees {
            guard let email = attendee.person.email,
                  let person = try await repositories.persons.person(email: email) else { continue }
            resolved.append(person)
        }
        return resolved
    }

    /// §7 «embeddingModelVersion»: первая непустая версия среди `transcript.speakers`;
    /// пустой `speakers` — штатный вход (запись только с микрофона, IR-128), версия — "".
    /// Спикеры есть, а версии нет ни у одного — испорченный вход, ранний отказ.
    private static func embeddingModelVersion(transcript: Transcript, transcriptId: UUID) throws -> String {
        guard !transcript.speakers.isEmpty else { return "" }
        guard let version = transcript.speakers.compactMap(\.embeddingModelVersion).first else {
            throw InputBuildFailure.embeddingModelVersionMissing(transcriptId: transcriptId)
        }
        return version
    }

    // MARK: - Применение AttributionResult (§7 «Применение»)

    static func apply(
        _ result: AttributionResult,
        transcriptId: UUID,
        transcripts: TranscriptRepository,
        speakerProfiles: SpeakerProfileRepository,
        now: Date
    ) async throws {
        if !result.segmentUpdates.isEmpty {
            try await transcripts.updateAttribution(result.segmentUpdates)
        }
        for update in result.profileUpdates {
            try await speakerProfiles.upsert(SpeakerProfile(
                personId: update.personId, embedding: update.embedding,
                modelVersion: update.modelVersion, sampleCount: update.sampleCount, updatedAt: now
            ))
        }
        try await applyTextCorrections(result.textCorrections, transcriptId: transcriptId, transcripts: transcripts)
    }

    /// §7: по одному вызову `applyTextCorrections` на сегмент, у которого правки этого
    /// сегмента непусты — не один вызов на весь результат. `text` строит вызывающий модуль,
    /// заменяя слова по `wordIndex`; способ склейки слов в строку — не предмет контракта.
    ///
    /// Сегмент из `textCorrections`, которого нет среди строк транскрипта (правка приёмки
    /// РП, PR #136, 03:15 UTC) — пропускается молча: применить правку неоткуда взять слова
    /// сегмента, а `text = ""` стёр бы содержимое строки, которой правка не касалась.
    private static func applyTextCorrections(
        _ corrections: [TextCorrection], transcriptId: UUID, transcripts: TranscriptRepository
    ) async throws {
        guard !corrections.isEmpty else { return }
        let bySegment = Dictionary(grouping: corrections, by: \.segmentId)
        let rows = try await transcripts.segments(transcriptId: transcriptId)
        let wordsBySegment = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.segment.words) })
        for (segmentId, segmentCorrections) in bySegment {
            guard let words = wordsBySegment[segmentId] else { continue }
            let text = correctedText(words: words, corrections: segmentCorrections)
            try await transcripts.applyTextCorrections(
                segmentId: segmentId, text: text, corrections: segmentCorrections
            )
        }
    }

    /// Правило при двух правках одного `wordIndex` (C-015 не гарантирует его уникальность
    /// в `textCorrections`) — правка приёмки РП, PR #136, 03:15 UTC: побеждает последняя
    /// по порядку в массиве.
    private static func correctedText(words: [Transcript.Word], corrections: [TextCorrection]) -> String {
        let replacementByIndex = Dictionary(
            corrections.map { ($0.wordIndex, $0.replacement) },
            uniquingKeysWith: { _, latest in latest }
        )
        return words.enumerated()
            .map { index, word in replacementByIndex[index] ?? word.text }
            .joined(separator: " ")
    }
}
