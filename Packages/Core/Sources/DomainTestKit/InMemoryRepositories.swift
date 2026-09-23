//  InMemoryRepositories — контейнер фейков репозиториев C-010, §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  КОНТЕЙНЕР НАЗВАН КОНТРАКТОМ, А НЕ ЗАВЕДЁН ЗДЕСЬ: «`DomainTestKit.InMemoryRepositories` —
//  ОДИН КОНТЕЙНЕР с реализациями всех восьми протоколов поверх словарей в памяти». Перечисление
//  §6 плана MEE-288 говорит «фейки репозиториев C-010» и ни контейнера, ни имён не называет.
//
//  ВОСЬМИ РЕАЛИЗАЦИЙ ЗДЕСЬ ПО-ПРЕЖНЕМУ НЕТ — ИХ ТРИ, И ЭТО НЕДОСТАЧА ДЕРЕВА, А НЕ РЕШЕНИЕ
//  КОНТЕЙНЕРА. MEE-319 объявил в `DomainCore` все восемь протоколов §5 и `FileLayout` §1
//  (было три из восьми и без `FileLayout` — MEE-289), но фейки пяти новых протоколов
//  (`PersonRepository`, `SpeakerProfileRepository`, `ConnectorRepository`,
//  `MeetingOutputRepository`, `SettingsRepository`) и `TemporaryFileLayout` — предмет
//  своей, второй задачи (МЕЕ-319, «Зачем»: «Остальные фейки — вторая задача»), не этой.
//  Единственное исключение — `RecordingRepository.adHoc()`: без него `InMemoryRecordingRepository`
//  не собирается, и MEE-319 дописал его фейку вместе с привязкой «запись → встреча»
//  (инвариант 7), не трогая прочие пять протоколов.
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

    /// - Parameter log: журнал вызовов. Не дали — контейнер заводит свой и отдаёт его
    ///   полем `log`, чтобы тот же объект можно было передать фейкам других портов.
    public init(log: PortCallLog = PortCallLog()) {
        self.log = log
        meetings = InMemoryMeetingRepository(log: log)
        recordings = InMemoryRecordingRepository(log: log)
        transcripts = InMemoryTranscriptRepository(log: log)
        recordings.attachCascade(transcripts: transcripts)
        meetings.attachCascade(recordings: recordings)
    }
}
