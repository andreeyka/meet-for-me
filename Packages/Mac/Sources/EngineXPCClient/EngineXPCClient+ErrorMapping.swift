//  EngineXPCClient — отображение отказов в `TranscriptionServiceError` (C-012 v10 §3.2).
//  Разведено из `EngineXPCClient.swift`/`EngineXPCClient+Transport.swift` по объёму.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (клиент NSXPCConnection)
//
//  Три источника отказа отображаются сюда порознь:
//  1. `EngineTransportFault.errorDomain` (§3.1) — коды `1..3` из `send`-реплая или прокси;
//     код `4` (сервис новее клиента, К33) вне диапазона — общий случай «нераспознанный код».
//  2. `NSCocoaErrorDomain` — настоящий `NSXPCConnection` (К51): `NSXPCConnectionInterrupted`/
//     `Invalid`/`ReplyInvalid` названы контрактом по имени константы, не по числу (числа —
//     деталь реализации Foundation).
//  3. Разобранный `EngineReply`, не подходящий ни одной ожидаемой форме вызова (К37, К39) —
//     не `NSError` вовсе, чистое отображение значения.

import Foundation
import DomainCore
import EngineKit

extension EngineXPCClient {

    /// К25, К31, К33: код и `userInfo` `EngineTransportFault`, либо настоящая ошибка
    /// `NSXPCConnection` (К51), либо что угодно постороннее — свести к общему виду.
    func map(nsError: NSError) -> TranscriptionServiceError {
        if nsError.domain == EngineTransportFault.errorDomain {
            return mapTransportFault(nsError)
        }
        if nsError.domain == NSCocoaErrorDomain {
            return mapCocoaConnectionError(nsError)
        }
        return .serviceUnavailable(message: describe(nsError))
    }

    private func mapTransportFault(_ nsError: NSError) -> TranscriptionServiceError {
        switch nsError.code {
        case EngineTransportFault.protocolVersionMismatch.rawValue:
            let client = intUserInfo(nsError, EngineTransportFault.clientProtocolVersionKey)
            let service = intUserInfo(nsError, EngineTransportFault.serviceProtocolVersionKey)
            return .protocolVersionMismatch(client: client, service: service)
        case EngineTransportFault.messageTooLarge.rawValue:
            return .messageTooLarge(bytes: intUserInfo(nsError, EngineTransportFault.messageBytesKey))
        case EngineTransportFault.invalidRequest.rawValue:
            let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String
            return .invalidRequest(message: message ?? "описание отсутствует")
        default:
            // К33: код вне 1...3 (сервис новее клиента) — тем же путём, что незнакомый код.
            return .invalidRequest(
                message: "нераспознанный код транспорта \(nsError.code): \(nsError.localizedDescription)"
            )
        }
    }

    /// К51: четыре вектора `NSCocoaErrorDomain`, дословно по имени константы.
    private func mapCocoaConnectionError(_ nsError: NSError) -> TranscriptionServiceError {
        switch nsError.code {
        case NSXPCConnectionInterrupted:
            return .serviceCrashed
        case NSXPCConnectionInvalid, NSXPCConnectionReplyInvalid:
            return .serviceUnavailable(message: nsError.localizedDescription)
        default:
            return .serviceUnavailable(message: describe(nsError))
        }
    }

    private func intUserInfo(_ nsError: NSError, _ key: String) -> Int {
        (nsError.userInfo[key] as? Int) ?? -1
    }

    /// К39, К51 (общий случай): «<домен> <код>: <описание>» — один формат на оба места,
    /// где контракт просит назвать домен и код постороннего отказа текстом.
    private func describe(_ nsError: NSError) -> String {
        "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    /// К37, К39: разобранный `EngineReply`, не подходящий ожидаемому виду ответа на ЭТОТ
    /// `jobId` — либо законный отказ движка/отмена, либо нарушение протокола ответа.
    static func outcome(for reply: EngineReply, expectedJobId: EngineJobId) -> Error {
        switch reply {
        case .failed(let jobId, let engineError) where jobId == expectedJobId:
            return TranscriptionServiceError.engineFailure(
                code: engineErrorCode(engineError), message: "\(engineError)"
            )
        case .cancelled(let jobId) where jobId == expectedJobId:
            return TranscriptionServiceError.cancelled
        default:
            return TranscriptionServiceError.serviceUnavailable(
                message: "нарушение протокола ответа: неожиданный кадр для \(expectedJobId)"
            )
        }
    }

    /// К37: `code` — имя случая `EngineError` дословно, не описание и не `String(describing:)`
    /// (тот отдаёт то же самое для перечисления без ассоциированных значений в имени пути,
    /// но здесь фиксируется явным словарём — не полагается на то, что синтез не поменяется).
    private static func engineErrorCode(_ error: EngineError) -> String {
        switch error {
        case .modelMissing: return "modelMissing"
        case .modelIncompatible: return "modelIncompatible"
        case .audioUnreadable: return "audioUnreadable"
        case .unsupportedLanguage: return "unsupportedLanguage"
        case .unsupportedRequest: return "unsupportedRequest"
        case .outOfMemory: return "outOfMemory"
        case .cancelled: return "cancelled"
        case .invalidResult: return "invalidResult"
        case .runtimeFailure: return "runtimeFailure"
        }
    }
}
