//  AppFacadeImpl — правка спикеров (C-016 v10, группы Д и Е плана MEE-410; К15-К20,
//  К50-К52 дельты Щ перечня MEE-401). Разведено из `AppFacadeImpl.swift` по объёму
//  (`file_length`), не по смыслу.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ГРУППЫ Д И Е — ОДНИМ ФАЙЛОМ, НЕ ПОРОЗНЬ: план MEE-410 сам держит их одним файлом теста
//  (`SpeakerAssignmentTests.swift`) с общими фикстурами (ФАП+ФТР+ФСР); `forgetVoiceProfile`
//  (Е, К20) в одиночку потребовал бы завести `AttributionPort` только ради проверки
//  «счётчик 0», хотя реально им пользуются только Д-методы.
//
//  `voiceProfilesEnabled` ЧИТАЕТСЯ ЧЕРЕЗ `self.settings()` (приёмка РП 07:30 UTC, после
//  того как MEE-425/группа Ж слилась в `main`, пока этот PR был на возврате) — БЫЛ литерал
//  `false` до этого слияния, потому что `settings()` до группы Ж бросал `notImplemented`.
//  `settings()` уже сам сводит отказы репозитория настроек к `AppFacadeError`
//  (`AppFacadeImpl+Settings.swift`) — эта ошибка пробрасывается наружу как есть, не
//  заворачивается повторно в `app.internalError`.
//
//  МЕСТО meetingId: у `assignSpeaker`/`clearSpeaker`/`createPersonAndAssign` нет параметра
//  `meetingId` (контракт не называет его для этих методов) — берётся тем же путём, что
//  `RecordingManifest.meetingId` хранит с самого `startRecording`: `transcript.recordingId`
//  → `recordings.recording(id:)` → `.manifest.meetingId`. `nil` для ad-hoc записи —
//  `AttributionSupport.buildInput` для этого случая уже определён (пустые `attendees`).
//
//  ПОМЕТКА `is_user_edited = 1` — ОТДЕЛЬНЫЙ ВЫЗОВ ПОСЛЕ ПРИМЕНЕНИЯ, НЕ ЧАСТЬ
//  `AttributionSupport.apply`. `TranscriptRepository.updateAttribution` инвариантом 17 её
//  не трогает («он остаётся тем, чем был» — своя дока метода), а `AttributionResult` не
//  несёт списка «эти сегменты теперь ручные». Инв. 13, третье предложение (К50 дельты Щ):
//  ручное назначение/снятие метит ВЕСЬ кластер — `markSegmentsUserEdited(segmentIds:)`
//  (C-010, инвариант 34, IR-135/MEE-421) на всех сегментах `cluster`, не только на тех, что
//  вошли в `segmentUpdates`. Отдельный вызов, не часть общей `AttributionSupport` — она же
//  обслуживает автоматическую атрибуцию (`AttributeJobHandler`), которой это чужое: там нет
//  одного выделенного кластера, который сейчас правит человек.

import Foundation

extension AppFacadeImpl {

    /// К15 (инв. 13, 14): `confirm` вызван с заданными `transcriptId`/`cluster`/`personId`;
    /// результат применён тремя вызовами (`updateAttribution`/`upsert`/`applyTextCorrections`),
    /// по одному на затронутую коллекцию. К50 (дельта Щ): сегменты `cluster` исключены из
    /// `userEditedSegmentIds`, даже если уже помечены, — иначе честный `AttributionPort`
    /// отфильтровал бы собственный ответ на переназначение этого же кластера (К52).
    public func assignSpeaker(transcriptId: UUID, cluster: Int, personId: UUID) async throws {
        try await confirmAndApply(transcriptId: transcriptId, cluster: cluster, personId: personId)
    }

    /// К17: `reject` не несёт `personId` — `SpeakerProfileRepository.upsert` не вызывается,
    /// когда `AttributionResult.profileUpdates` пуст (то же применение, что у К15).
    public func clearSpeaker(transcriptId: UUID, cluster: Int) async throws {
        do {
            let meetingId = try await recordingMeetingId(transcriptId: transcriptId)
            let voiceProfilesEnabled = try await settings().voiceProfilesEnabled
            let input = try await AttributionSupport.buildInput(
                transcriptId: transcriptId, meetingId: meetingId, excludingClusterFromUserEdited: cluster,
                repositories: attributionRepositories(), voiceProfilesEnabled: voiceProfilesEnabled
            )
            let result = try await attribution.reject(transcriptId: transcriptId, cluster: cluster, input: input)
            try await applyResultAndMarkCluster(result, transcriptId: transcriptId, cluster: cluster)
        } catch let error as AppFacadeError {
            throw error
        } catch let error as AttributionError {
            throw wrap(error)
        } catch let failure as AttributionSupport.InputBuildFailure {
            throw wrap(failure)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// К19: `email` привязан там, где задан (`upsert(displayName:emails:)` дословно
    /// принимает пустой список, когда `email == nil`); дальше та же последовательность,
    /// что К15 — `confirm` для нового `personId`.
    public func createPersonAndAssign(
        transcriptId: UUID, cluster: Int, displayName: String, email: String?
    ) async throws -> UUID {
        // `confirmAndApply` уже сводит свои отказы к `AppFacadeError` изнутри — обёртка
        // здесь ловит только `persons.upsert`, чтобы не завернуть готовый AppFacadeError
        // повторно в app.internalError.
        let personId: UUID
        do {
            personId = try await persons.upsert(displayName: displayName, emails: email.map { [$0] } ?? [])
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        try await confirmAndApply(transcriptId: transcriptId, cluster: cluster, personId: personId)
        return personId
    }

    /// К20: удаляет голосовой профиль человека; `AttributionPort` этим методом не
    /// вызывается вовсе (контракт не связывает эти две вещи — `forgetVoiceProfile` предмет
    /// C-010, не C-015).
    public func forgetVoiceProfile(personId: UUID) async throws {
        do {
            try await speakerProfiles.delete(personId: personId)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// Общее тело К15/К19 — оба заканчиваются `confirm` с уже известным `personId`
    /// (свежесозданным у К19, переданным вызывающей стороной у К15).
    private func confirmAndApply(transcriptId: UUID, cluster: Int, personId: UUID) async throws {
        do {
            let meetingId = try await recordingMeetingId(transcriptId: transcriptId)
            let voiceProfilesEnabled = try await settings().voiceProfilesEnabled
            let input = try await AttributionSupport.buildInput(
                transcriptId: transcriptId, meetingId: meetingId, excludingClusterFromUserEdited: cluster,
                repositories: attributionRepositories(), voiceProfilesEnabled: voiceProfilesEnabled
            )
            let result = try await attribution.confirm(
                transcriptId: transcriptId, cluster: cluster, personId: personId, input: input
            )
            try await applyResultAndMarkCluster(result, transcriptId: transcriptId, cluster: cluster)
        } catch let error as AppFacadeError {
            throw error
        } catch let error as AttributionError {
            throw wrap(error)
        } catch let failure as AttributionSupport.InputBuildFailure {
            throw wrap(failure)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }

    /// К16: пометка идёт ПОСЛЕ всех трёх вызовов применения (`AttributionSupport.apply`),
    /// не только после последнего. К51 (дельта Щ): помечен ВЕСЬ кластер — каждый его сегмент,
    /// не только те, что попали в `segmentUpdates`, — и ни один сегмент другого кластера.
    ///
    /// К33 (МЕЕ-437, группа Л): общая точка для всех трёх вызывающих методов
    /// (`assignSpeaker`/`clearSpeaker`/`createPersonAndAssign`) — публикация здесь одна на
    /// всех троих, а не по копии в каждом.
    private func applyResultAndMarkCluster(
        _ result: AttributionResult, transcriptId: UUID, cluster: Int
    ) async throws {
        try await AttributionSupport.apply(
            result, transcriptId: transcriptId, transcripts: transcripts,
            speakerProfiles: speakerProfiles, now: clock()
        )
        let segmentIds = try await clusterSegmentIds(transcriptId: transcriptId, cluster: cluster)
        try await transcripts.markSegmentsUserEdited(segmentIds: segmentIds)
        publish(.transcriptChanged(transcriptId: transcriptId))
    }

    private func clusterSegmentIds(transcriptId: UUID, cluster: Int) async throws -> [Int64] {
        let rows = try await transcripts.segments(transcriptId: transcriptId)
        return rows.filter { $0.segment.speakerCluster == cluster }.map(\.id)
    }

    private func attributionRepositories() -> AttributionSupport.Repositories {
        AttributionSupport.Repositories(
            transcripts: transcripts, meetings: meetingRepository, persons: persons, speakerProfiles: speakerProfiles
        )
    }

    private func recordingMeetingId(transcriptId: UUID) async throws -> UUID? {
        guard let transcript = try await transcripts.transcript(id: transcriptId) else {
            throw AttributionSupport.InputBuildFailure.transcriptNotFound(transcriptId)
        }
        let recording = try await recordings.recording(id: transcript.recordingId)
        return recording?.manifest.meetingId
    }

    private func wrap(_ failure: AttributionSupport.InputBuildFailure) -> AppFacadeError {
        switch failure {
        case .transcriptNotFound(let id):
            return .notFound(entity: "Transcript", id: id.uuidString)
        case .embeddingModelVersionMissing:
            return wrapUnexpected(failure)
        }
    }

    /// Инв. 19, §3.1: шесть кейсов `AttributionError`, ни одному не нужен `permissionKind`.
    /// Приёмка РП (MEE-420, 07:30 UTC): явный `switch`, а не разбор `String(describing:)` —
    /// шесть случаев далеко не упираются в `cyclomatic_complexity` (порог 10), в отличие от
    /// одиннадцати у `CaptureError` в `AppFacadeImpl+Recording.swift`.
    private func wrap(_ error: AttributionError) -> AppFacadeError {
        let code: String
        switch error {
        case .unknownTranscript:
            code = "attribution.unknownTranscript"
        case .unknownCluster:
            code = "attribution.unknownCluster"
        case .unknownPerson:
            code = "attribution.unknownPerson"
        case .embeddingModelMismatch:
            code = "attribution.embeddingModelMismatch"
        case .segmentIdsMismatch:
            code = "attribution.segmentIdsMismatch"
        case .voiceProfilesDisabled:
            code = "attribution.voiceProfilesDisabled"
        }
        return .underlying(AppErrorView(
            code: code, message: String(describing: error), recoverySuggestion: nil, permissionKind: nil
        ))
    }
}
