//  InMemoryRepositories — контейнер фейков репозиториев C-010, §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  КОНТЕЙНЕР НАЗВАН КОНТРАКТОМ, А НЕ ЗАВЕДЁН ЗДЕСЬ: «`DomainTestKit.InMemoryRepositories` —
//  ОДИН КОНТЕЙНЕР с реализациями всех восьми протоколов поверх словарей в памяти». Перечисление
//  §6 плана MEE-288 говорит «фейки репозиториев C-010» и ни контейнера, ни имён не называет.
//
//  ВОСЬМЬ РЕАЛИЗАЦИЙ (MEE-320). MEE-319 объявил в `DomainCore` все восемь протоколов §5 и
//  `FileLayout` §1 (было три из восьми и без `FileLayout` — MEE-289) и дописал
//  `InMemoryRecordingRepository.adHoc()` (инвариант 7/29), не заводя фейков пяти новых
//  протоколов — «Остальные фейки — вторая задача». MEE-320 заводит пять оставшихся:
//  `InMemoryPersonRepository`, `InMemorySpeakerProfileRepository`, `InMemoryConnectorRepository`,
//  `InMemoryMeetingOutputRepository`, `InMemorySettingsRepository`.
//
//  ЗАЧЕМ КОНТЕЙНЕР НУЖЕН, ЕСЛИ РЕПОЗИТОРИИ СОБИРАЮТСЯ И ПОРОЗНЬ, — две причины, и обе
//  измеримы, а не стилистические:
//    1. ОДИН ЖУРНАЛ ВЫЗОВОВ на все порты. Условие `Н` плана требует последовательности
//       ПОПЕРЁК портов: К40 просит наблюсти «сохранение → вход → постановка», К77 —
//       «`RecordingRepository.save` → вход в `processing` → `JobQueue.submit`». Порознь
//       заведённые журналы на это не отвечают: у каждого свой порядок.
//    2. КАСКАД инварианта 8 — удаление записи уносит её транскрипты, а те сегменты. Каскад
//       по построению межпортовый, и у одиночного репозитория ему уходить некуда.

import Foundation
import DomainCore

/// Контейнер фейков репозиториев, собранных на одном журнале вызовов.
public final class InMemoryRepositories: @unchecked Sendable {

    /// Журнал, общий для всех фейков контейнера; в него же пишут фейки очереди и захвата,
    /// если их собрали с этим журналом.
    public let log: PortCallLog

    public let meetings: InMemoryMeetingRepository
    public let recordings: InMemoryRecordingRepository
    public let transcripts: InMemoryTranscriptRepository
    public let persons: InMemoryPersonRepository
    public let speakerProfiles: InMemorySpeakerProfileRepository
    public let connectors: InMemoryConnectorRepository
    public let meetingOutputs: InMemoryMeetingOutputRepository
    public let settings: InMemorySettingsRepository

    /// - Parameter log: журнал вызовов. Не дали — контейнер заводит свой и отдаёт его
    ///   полем `log`, чтобы тот же объект можно было передать фейкам других портов.
    public init(log: PortCallLog = PortCallLog()) {
        self.log = log
        meetings = InMemoryMeetingRepository(log: log)
        recordings = InMemoryRecordingRepository(log: log)
        transcripts = InMemoryTranscriptRepository(log: log)
        persons = InMemoryPersonRepository(log: log)
        speakerProfiles = InMemorySpeakerProfileRepository(log: log)
        connectors = InMemoryConnectorRepository(log: log)
        meetingOutputs = InMemoryMeetingOutputRepository(log: log)
        settings = InMemorySettingsRepository(log: log)
        recordings.attachCascade(transcripts: transcripts)
        meetings.attachCascade(recordings: recordings)
    }
}
