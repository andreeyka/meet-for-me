//  StorageErrorMapping — «Ошибки», C-010 (MEE-18) v7, «Поведение», подраздел «Ошибки».
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  Правило по событию, а не по списку колонок (контракт, «Поведение»): всякая строка,
//  прочитанная, но не сложившаяся в доменный тип, даёт `StorageError.dataCorrupted`,
//  а не `nil` и не `io` (инвариант 21). Единственное разрешённое исключение —
//  `JobRepository.jobs(status:)` (инвариант 24) — реализовано отдельно, часть с
//  `JobRepository`.

import Foundation
import GRDB
import DomainCore

/// Имена доменных типов словаря `entity` подраздела «Ошибки» — дословно по контракту.
enum StorageEntity {
    static let meeting = "Meeting"
    static let person = "Person"
    static let recording = "Recording"
    static let transcript = "Transcript"
    static let segment = "Segment"
    static let job = "Job"
    static let connector = "Connector"
    static let speakerProfile = "SpeakerProfile"
    static let meetingOutput = "MeetingOutput"
    static let setting = "Setting"
}

enum StorageErrorMapping {

    /// Сводит любую ошибку, пойманную на чтении/записи строки, к `StorageError`
    /// (инвариант 21): `DecodingError` и `DomainValidationError` — в `dataCorrupted`
    /// с `message`, несущим описание исходной ошибки целиком (инвариант 22);
    /// нарушение ограничения БД — в `constraintViolation`; всё прочее — в `io`.
    static func map(_ error: Error, entity: String, id: String) -> StorageError {
        if let already = error as? StorageError {
            return already
        }
        if let decoding = error as? DecodingError {
            return .dataCorrupted(entity: entity, id: id, message: String(describing: decoding))
        }
        if let validation = error as? DomainValidationError {
            return .dataCorrupted(entity: entity, id: id, message: validation.description)
        }
        if let dbError = error as? DatabaseError {
            if dbError.resultCode == .SQLITE_CONSTRAINT {
                return .constraintViolation(message: dbError.description)
            }
            return .io(message: dbError.description)
        }
        return .io(message: String(describing: error))
    }

    /// Нарушение ограничения БД вне пути чтения строки (например, отклонённая
    /// вставка) — сведение в `constraintViolation`/`io` без словаря `entity`/`id`.
    static func mapWrite(_ error: Error) -> StorageError {
        if let already = error as? StorageError {
            return already
        }
        if let dbError = error as? DatabaseError {
            if dbError.resultCode == .SQLITE_CONSTRAINT {
                return .constraintViolation(message: dbError.description)
            }
            return .io(message: dbError.description)
        }
        return .io(message: String(describing: error))
    }
}

/// Инвариант 27: колонки JSON читаются и пишутся `DomainJSON`, собственного
/// `JSONDecoder`/`JSONEncoder` модуль не собирает нигде (К44) — включая
/// `meetings.dedup_key`, которая формату инварианта 27 не подчинена («Что вне
/// контракта»), но вторым декодером всё равно не обзаводится: тот же механизм
/// дешевле собственного и не рискует разойтись с ним на границах (`1e400` и т. п.).
enum StorageJSON {

    static func encodeToText<Value: Encodable>(_ value: Value) throws -> String {
        let data = try DomainJSON.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StorageError.io(message: "DomainJSON.encode вернул байты вне UTF-8")
        }
        return text
    }

    static func decodeFromText<Value: Decodable>(
        _ type: Value.Type,
        from text: String,
        entity: String,
        id: String
    ) throws -> Value {
        guard let data = text.data(using: .utf8) else {
            throw StorageError.dataCorrupted(entity: entity, id: id, message: "колонка не в UTF-8")
        }
        do {
            return try DomainJSON.decode(type, from: data)
        } catch {
            throw StorageErrorMapping.map(error, entity: entity, id: id)
        }
    }
}

/// Время — `INTEGER`, секунды Unix epoch в UTC (C-010 §2).
enum EpochTime {
    static func seconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded())
    }

    static func date(fromSeconds seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
