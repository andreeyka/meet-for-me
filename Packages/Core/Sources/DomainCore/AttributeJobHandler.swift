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
//  ХВОСТ MEE-415 ЗАКРЫТ MEE-420: §7 называет единственный источник `voiceProfilesEnabled` —
//  `AppFacade.settings()` (C-016) — теперь зависимость на настоящий `AppFacade`, не на
//  временное замыкание. К33 (передача флага, гейт `profiles`) — построение входа ниже;
//  К49 (`AppFacadeError` → `JobOutcome` по случаю `settingsUnreadable`/`underlying`) — свой
//  `catch` в `run(_:progress:)`: `settingsUnreadable` — данные не читаются, повтор с тем же
//  ключом даст тот же результат, `permanentFailure`; `underlying` с кодом `storage.io` —
//  переходный отказ хранилища, тот же довод и та же лестница, что у `StorageError.io`
//  ниже, `retry(after: 30)`; любой другой случай `AppFacadeError` из `settings()` контракт
//  не предусматривает (§2.1 называет только эти два пути) — `permanentFailure` как более
//  безопасный исход неизвестного случая.
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
    private let appFacade: AppFacade

    public init(
        port: AttributionPort,
        transcripts: TranscriptRepository,
        meetings: MeetingRepository,
        persons: PersonRepository,
        speakerProfiles: SpeakerProfileRepository,
        appFacade: AppFacade
    ) {
        self.port = port
        self.transcripts = transcripts
        self.meetings = meetings
        self.persons = persons
        self.speakerProfiles = speakerProfiles
        self.appFacade = appFacade
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
            try await AttributionSupport.apply(
                result, transcriptId: transcriptId, transcripts: transcripts,
                speakerProfiles: speakerProfiles, now: Date()
            )
            return .success
        } catch let failure as AttributionSupport.InputBuildFailure {
            return .permanentFailure(error: failure.message)
        } catch let error as AppFacadeError {
            return Self.outcome(for: error)
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

    /// К49 (§2.1 C-016 дословно): `settings()` называет ровно два пути отказа.
    /// `settingsUnreadable` — байты значения не разбираются в объявленный тип; повтор с
    /// той же строкой базы даёт тот же результат, `permanentFailure`. `underlying` с
    /// кодом `storage.io` — переходный отказ хранилища под `settings()`, тот же довод и
    /// та же лестница C-013 §5, что у `StorageError.io`, `retry(after: 30)`. Любой другой
    /// случай `AppFacadeError` контракт для `settings()` не называет — `permanentFailure`.
    private static func outcome(for error: AppFacadeError) -> JobOutcome {
        switch error {
        case .settingsUnreadable:
            return .permanentFailure(error: "\(error)")
        case .underlying(let view) where view.code == "storage.io":
            return .retry(after: 30, error: view.code)
        default:
            return .permanentFailure(error: "\(error)")
        }
    }

    // MARK: - Построение AttributionInput (§7) — общая логика в AttributionSupport (MEE-420)

    private func buildInput(transcriptId: UUID, meetingId: UUID?) async throws -> AttributionInput {
        let voiceEnabled = try await appFacade.settings().voiceProfilesEnabled
        let repositories = AttributionSupport.Repositories(
            transcripts: transcripts, meetings: meetings, persons: persons, speakerProfiles: speakerProfiles
        )
        return try await AttributionSupport.buildInput(
            transcriptId: transcriptId, meetingId: meetingId, excludingClusterFromUserEdited: nil,
            repositories: repositories, voiceProfilesEnabled: voiceEnabled
        )
    }
}
