//  HALStatusMapping — код возврата системного вызова → `ProcessMonitorError?`. Шов Ш3.
//
//  C-009 §«Поведение», «Отказ по праву», следствия IR-029:
//  1. признак отказа по праву определяется реализацией и держится В ОДНОМ МЕСТЕ — здесь;
//     `permissionRequired` не конструируется больше нигде в модуле;
//  2. до ручного замера (Р1) правило «тогда и только тогда» не проверено ни одной работой CI:
//     проверяются тотальность отображения и то, что неизвестный код не даёт отказа по праву;
//  3. после замера признак вносится в контракт `interface-request`-ом.
//
//  КОД, НАЗВАННЫЙ ЗДЕСЬ ПРИЗНАКОМ ОТКАЗА ПО ПРАВУ, НЕ ИЗМЕРЕН НИКЕМ. Спайк MEE-8 отказа не
//  получил ни разу. Выбран `kAudioHardwareIllegalOperationError` ('nope') — это догадка
//  реализации, и она названа догадкой: порт не проверяет право заранее и не выводит его из
//  версии системы, он только сверяет код, который вернул вызов.

import CoreAudio
import DomainCore
import Foundation

enum HALStatusMapping {

    /// Признак отказа по причине отсутствия права. Не измерен (Р1).
    static let permissionDeniedStatus = Int32(kAudioHardwareIllegalOperationError)

    /// Отображение тотально: `0` — ошибки нет; признанный код — отказ по праву для тех данных,
    /// которые давал отказавший вызов; любой другой ненулевой код — система недоступна.
    static func error(for status: Int32, call: String, data kind: PermissionKind) -> ProcessMonitorError? {
        switch status {
        case 0:
            return nil
        case permissionDeniedStatus:
            return .permissionRequired(kind)
        default:
            return .systemUnavailable(message: "\(call): OSStatus \(status) (\(fourCharacterCode(status)))")
        }
    }

    /// Четырёхсимвольный код HAL для сообщения; число, если символы непечатаемы.
    static func fourCharacterCode(_ status: Int32) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ (32..<127).contains($0) }),
              let code = String(bytes: bytes, encoding: .ascii) else { return String(status) }
        return code
    }
}
