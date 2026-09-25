//  InMemoryRecordingRepository — реализация `RecordingRepository` поверх словаря, C-010
//  §«Фейк для тестов». Имя взято у контракта.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ЧТО ДЕРЖИТСЯ ИЗ ИНВАРИАНТОВ, названо поимённо:
//    * инвариант 13 — `directory_name` уникален и равен `UUID.uuidString` записи — ДЕРЖИТСЯ
//      БЕЗ ЕДИНОЙ СТРОКИ ЗДЕСЬ, и это замер, а не рассуждение. Первую половину держит сам тип:
//      `RecordingManifest.validate()` проверяет `directoryName == recordingId.uuidString`
//      (C-002, инвариант 7), и значения, нарушающего её, не существует — собрать его нечем.
//      Вторую держит устройство хранилища: записи лежат словарём по `recordingId`, а имя
//      каталога есть функция от него, значит два разных имени у одного ключа невозможны.
//      Проверка в `save` была написана и СНЯТА: она недостижима ни на одном входе, то есть
//      зелена по построению (правило 7 проекта). Замер — вектором в `InMemoryRepositoriesTests`;
//    * инвариант 14 — файлов на диске фейк не трогает вовсе: их у него нет;
//    * инвариант 20 — чтения отдают `nil` и пустой массив, `notFound` не бросает ни одно
//      из них; у этого порта методов, обязанных изменить существующую строку, нет.
//
//  ПРЕДИКАТ `unfinalized()` НАЗВАН ЯВНО, потому что контракт его не определяет: запись
//  входит в ответ тогда и только тогда, когда её `RecordingStatus` НЕ РАВЕН `.finalized`.
//  Имя читается буквально, и на этом чтении сходится К77: его вход — «хранилище с записью
//  в КАЖДОМ значении `RecordingStatus`», а ответ разбирает `.recording`/`.stopping` (зовём
//  `recover`), `.failed` (сессии не заводим) и `.finalized` (в `unfinalized()` не попадает
//  вовсе). Предикат «не `.finalized`» отдаёт ровно первые три. Это решение фейка, а не
//  утверждение о порте.
//
//  ПРИВЯЗКА «ЗАПИСЬ → ВСТРЕЧА» (MEE-319, C-010 v7, инвариант 7) — ОТДЕЛЬНАЯ ОТ
//  `RecordingManifest.meetingId`, КАК ТРЕБУЕТ КОНТРАКТ: «Текущую принадлежность записи
//  встрече домен читает по колонке… а не по `manifest.meetingId`». `save()` заводит
//  привязку из `manifest.meetingId` ОДИН РАЗ, при первом появлении записи, и больше её не
//  трогает; манифест неизменяем (C-002), и перечитывать его при каждом `save()` вернуло бы
//  устаревшее значение после каскада. Снимает привязку только каскад инварианта 7 —
//  `detachFromDeletedMeetings(_:)`, которую зовёт `InMemoryMeetingRepository.delete`
//  через `attachCascade(recordings:)`, тем же устройством, что уже держит каскад
//  инварианта 8 (`transcripts`, ниже). `recordings(meetingId:)` и `adHoc()` читают
//  привязку, а не `record.manifest.meetingId` — на этом стоят инварианты 7, 28 и 29
//  (К48, К86).
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА.

import Foundation
import DomainCore

/// Метод репозитория записей — адрес заданного тестом отказа.
public enum RecordingRepositoryMethod: String, Sendable, CaseIterable {
    case save
    case recordingById
    case recordingsByMeeting
    case unfinalized
    case adHoc
    case delete
    case createDirectory
}

/// Фейк репозитория записей. Всё поведение задаёт тест.
public final class InMemoryRecordingRepository: RecordingRepository, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "RecordingRepository"

    private let lock = NSLock()
    private let log: PortCallLog

    private var records: [UUID: RecordingRecord] = [:]
    private var order: [UUID] = []
    private var failures: [RecordingRepositoryMethod: (id: String?, error: StorageError)] = [:]
    private var deletedDirectories: [String] = []
    private var createdDirectories: [UUID] = []

    /// Привязка «запись → встреча» (инвариант 7 C-010 v7), отдельная от
    /// `RecordingManifest.meetingId`. Ключ — `recordingId`; запись присутствует в словаре
    /// тогда и только тогда, когда она привязана к встрече. Заводится `save()` один раз,
    /// при первом появлении записи; снимается только `detachFromDeletedMeetings(_:)`.
    private var meetingBinding: [UUID: UUID] = [:]

    /// Каскад по инварианту 8: удаление записи уносит её транскрипты. Ставится контейнером
    /// `InMemoryRepositories`; у одиночного репозитория каскаду уходить некуда, и его нет.
    private weak var transcripts: InMemoryTranscriptRepository?

    public init(log: PortCallLog = PortCallLog()) {
        self.log = log
    }

    /// Журнал, в который пишет этот фейк. Тот же объект, что передали в инициализатор.
    public var callLog: PortCallLog { log }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    /// Положить записи мимо `save`: вход теста, а не вызов порта. В журнал не пишется,
    /// инвариант 13 при этом НЕ проверяется — вход теста не связан ничем.
    public func seed(_ list: [RecordingRecord]) {
        locked {
            for record in list {
                let identifier = record.manifest.recordingId
                if records[identifier] == nil {
                    order.append(identifier)
                    // Та же привязка, что заводит `save()` — иначе `seed()` и `save()`
                    // расходятся в устройстве одного и того же инварианта 7.
                    if let meetingId = record.manifest.meetingId {
                        meetingBinding[identifier] = meetingId
                    }
                }
                records[identifier] = record
            }
        }
    }

    public func fail(with error: StorageError, on method: RecordingRepositoryMethod, id: String? = nil) {
        locked { failures[method] = (id: id, error: error) }
    }

    public func clearFailure(on method: RecordingRepositoryMethod) {
        locked { failures[method] = nil }
    }

    /// Каталоги, которые `delete(recordingId:deleteFiles: true)` объявил удалёнными.
    /// Файлов у фейка нет; это НАБЛЮДАЕМОСТЬ намерения, а не запись об удалении с диска.
    public var directoriesAskedToDelete: [String] {
        locked { deletedDirectories }
    }

    /// `recordingId`, для которых `createDirectory(recordingId:)` вернул URL, по порядку
    /// вызова — та же наблюдаемость намерения, что и `directoriesAskedToDelete`, симметрично
    /// (MEE-440). Файлов у фейка по-прежнему нет (инвариант 14) — здесь только адрес вызова.
    public var directoriesCreated: [UUID] {
        locked { createdDirectories }
    }

    public var storedRecords: [RecordingRecord] {
        locked { order.compactMap { records[$0] } }
    }

    /// Подключить каскад инварианта 8. Зовёт контейнер `InMemoryRepositories`.
    public func attachCascade(transcripts: InMemoryTranscriptRepository) {
        self.transcripts = transcripts
    }

    /// Каскад инварианта 7: удаление встречи обнуляет привязку «запись → встреча» у ЕЁ
    /// записей. Манифест (C-002) не трогается — он неизменяем, и его `meetingId` после
    /// этого может устареть; текущую принадлежность держит привязка, а не манифест.
    /// Зовёт `InMemoryMeetingRepository.delete(meetingIds:)` через `attachCascade(recordings:)`.
    public func detachFromDeletedMeetings(_ meetingIds: Set<UUID>) {
        locked {
            for (recordingId, boundMeetingId) in meetingBinding where meetingIds.contains(boundMeetingId) {
                meetingBinding.removeValue(forKey: recordingId)
            }
        }
    }

    /// C-010 v21, инвариант 33: переносит привязку «запись → встреча» с проигравших на
    /// победителя — шаг (1) `save(_:absorbing:)`, до удаления проигравших (в отличие от
    /// `detachFromDeletedMeetings`, которая её снимает). Зовёт
    /// `InMemoryMeetingRepository.save(_:absorbing:)` — единственный вызывающий, наружу
    /// поверхности не несёт (возврат РП, приёмка #134).
    func reassignFromDeletedMeetings(_ losingIds: Set<UUID>, to winnerId: UUID) {
        locked {
            for (recordingId, boundMeetingId) in meetingBinding where losingIds.contains(boundMeetingId) {
                meetingBinding[recordingId] = winnerId
            }
        }
    }

    // MARK: - Оснастка

    private func failureIfAny(_ method: RecordingRepositoryMethod, id: String?) -> StorageError? {
        locked { () -> StorageError? in
            guard let failure = failures[method] else { return nil }
            guard let wanted = failure.id else { return failure.error }
            return wanted == id ? failure.error : nil
        }
    }

    // MARK: - RecordingRepository

    public func save(_ record: RecordingRecord) async throws {
        let identifier = record.manifest.recordingId
        log.record(
            port: Self.portName,
            method: "save(_:)",
            arguments: [identifier.uuidString, record.status.rawValue]
        )
        if let error = failureIfAny(.save, id: identifier.uuidString) {
            throw error
        }
        locked {
            if records[identifier] == nil {
                order.append(identifier)
                // Привязка заводится из манифеста ОДИН РАЗ, при первом появлении записи
                // (инвариант 7 C-010 v7) — см. шапку файла.
                //
                // СТРОКА: что делает `save()` с привязкой при ПОВТОРНОЙ записи того же
                // `recordingId`. Контракт не говорит, пересчитывать ли колонку заново на
                // каждый `save()` или только на первый; «Фейк для тестов» требует держать
                // инвариант 7, а не выбор между двумя устройствами реализации. Оба законных
                // исхода: (а) не пересчитывать — как здесь; цена — если домен когда-нибудь
                // пересохранит запись с манифестом, чей `meetingId` разошёлся с уже осевшей
                // привязкой (контракт такого сценария не описывает и не ожидает), новое
                // значение молча проигнорируется. (б) пересчитывать на каждый `save()`; цена
                // прямая и измеримая: повторный `save()` ТЕМ ЖЕ (старым) манифестом ПОСЛЕ
                // каскада инварианта 7 молча восстановил бы привязку, которую каскад снял, —
                // это отменяло бы ровно то устройство, ради которого заведена привязка.
                // Беру (а): (б) ломает инвариант 7 на первом же реалистичном входе.
                if let meetingId = record.manifest.meetingId {
                    meetingBinding[identifier] = meetingId
                }
            }
            records[identifier] = record
        }
    }

    public func recording(id: UUID) async throws -> RecordingRecord? {
        log.record(port: Self.portName, method: "recording(id:)", arguments: [id.uuidString])
        if let error = failureIfAny(.recordingById, id: id.uuidString) {
            throw error
        }
        return locked { records[id] }
    }

    public func recordings(meetingId: UUID) async throws -> [RecordingRecord] {
        log.record(port: Self.portName, method: "recordings(meetingId:)", arguments: [meetingId.uuidString])
        if let error = failureIfAny(.recordingsByMeeting, id: meetingId.uuidString) {
            throw error
        }
        // Инвариант 7: принадлежность читается по привязке (колонка), не по манифесту —
        // после каскада `manifest.meetingId` может быть устаревшим значением.
        return locked {
            order
                .compactMap { records[$0] }
                .filter { meetingBinding[$0.manifest.recordingId] == meetingId }
        }
    }

    public func unfinalized() async throws -> [RecordingRecord] {
        log.record(port: Self.portName, method: "unfinalized()")
        if let error = failureIfAny(.unfinalized, id: nil) {
            throw error
        }
        return locked {
            order
                .compactMap { records[$0] }
                .filter { $0.status != .finalized }
        }
    }

    /// Инвариант 29: записи без привязки к встрече, независимо от `status` — ad-hoc
    /// с рождения и записи, чья встреча удалена каскадом (инвариант 7). Предикат читает
    /// привязку, а не `manifest.meetingId` (К86 (ii): после каскада манифест по-прежнему
    /// несёт старый идентификатор, а привязки уже нет).
    public func adHoc() async throws -> [RecordingRecord] {
        log.record(port: Self.portName, method: "adHoc()")
        if let error = failureIfAny(.adHoc, id: nil) {
            throw error
        }
        return locked {
            order
                .compactMap { records[$0] }
                .filter { meetingBinding[$0.manifest.recordingId] == nil }
        }
    }

    /// MEE-440: инвариант 14 держится тем же приёмом, что и весь остальной файл — фейк не
    /// трогает диск ни здесь, ни в `delete`. URL заведомо синтетический (`/dev/null/…`) —
    /// адрес для сравнения в тесте (`directoriesCreated`), не путь для чтения/записи.
    public func createDirectory(recordingId: UUID) async throws -> URL {
        log.record(port: Self.portName, method: "createDirectory(recordingId:)", arguments: [recordingId.uuidString])
        if let error = failureIfAny(.createDirectory, id: recordingId.uuidString) {
            throw error
        }
        locked { createdDirectories.append(recordingId) }
        return URL(fileURLWithPath: "/dev/null/InMemoryRecordingRepository/recordings")
            .appendingPathComponent(recordingId.uuidString)
    }

    public func delete(recordingId: UUID, deleteFiles: Bool) async throws {
        log.record(
            port: Self.portName,
            method: "delete(recordingId:deleteFiles:)",
            arguments: [recordingId.uuidString, String(deleteFiles)]
        )
        if let error = failureIfAny(.delete, id: recordingId.uuidString) {
            throw error
        }
        let removed = locked { () -> RecordingRecord? in
            let taken = records.removeValue(forKey: recordingId)
            order.removeAll { $0 == recordingId }
            meetingBinding.removeValue(forKey: recordingId)
            return taken
        }
        if deleteFiles, let removed {
            locked { deletedDirectories.append(removed.manifest.directoryName) }
        }
        // Инвариант 8: удаление записи каскадно уносит её транскрипты, а те — сегменты.
        transcripts?.cascadeDelete(recordingId: recordingId)
    }
}
