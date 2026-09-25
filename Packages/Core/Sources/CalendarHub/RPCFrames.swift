//  Кадры JSON-RPC 2.0 хоста stdio calendar-hub (C-006 §2, §3, §5, §5.1) — типы
//  RPCRequest/RPCResponse/RPCError, которые называет §2 контракта дословно по имени, форму
//  которых решает эта задача (MEE-402 шаг 2). Внутреннее дело хоста — границу модуля не
//  пересекают, поэтому не `public` (инв. 21, C-006 v14 §2).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import DomainCore

enum RPCFrameLimits {
    /// Версия конверта кадров (не версия протокола плагина — та в `protocolVersion`
    /// манифеста и рукопожатии `initialize`, см. `PluginManifest.swift`). Целое поле,
    /// строгое чтение `DomainJSON.decodeBounded` (инв. 16, К51) — несовпадение или
    /// отсутствие ключа отвергает кадр целиком, разбор `params`/`result` не начинается.
    static let schemaVersion = 1
    /// Кадр длиннее — хост закрывает соединение с `protocolViolation` (C-006 §2, К48 вход А).
    static let maxFrameBytes = 8 * 1024 * 1024
}

/// Исходящий кадр хоста — всегда `request` (несёт `id`); уведомлений от хоста плагину
/// контракт не описывает, и эта задача их не заводит.
struct RPCRequestFrame<Params: Encodable>: Encodable {
    let schemaVersion: Int
    let jsonrpc: String
    let id: Int
    let method: String
    let params: Params?

    init(id: Int, method: String, params: Params?) {
        schemaVersion = RPCFrameLimits.schemaVersion
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Тело ошибки кадра-ответа (§5). `retryAfterSecondsRaw` — единственное поле `data`, которое
/// читает эта задача (§5.2): снисходительное чтение (`try?` вокруг `decodeFiniteIfPresent`),
/// не строгое `decodeBounded` — отсутствие, нецелое, отрицательное значение или вне
/// представимости `Double` (`1e400`) единообразно превращаются в `nil`, а не в отказ разбора
/// всего кадра-ответа.
struct RPCErrorObject: Decodable {
    let code: Int
    let message: String
    let retryAfterSecondsRaw: Double?

    private enum CodingKeys: String, CodingKey { case code, message, data }
    private enum DataKeys: String, CodingKey { case retryAfterSeconds }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        code = try box.decodeBounded(Int.self, forKey: .code)
        message = try box.decode(String.self, forKey: .message)
        if let dataBox = try? box.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
            retryAfterSecondsRaw = try? dataBox.decodeFiniteIfPresent(Double.self, forKey: .retryAfterSeconds)
        } else {
            retryAfterSecondsRaw = nil
        }
    }
}

/// Различает `result`/`error` по наличию ключа, не по значению.
enum RPCOutcome<Result> {
    case value(Result)
    case failure(RPCErrorObject)
}

struct RPCResponseBody<Result: Decodable>: Decodable {
    let outcome: RPCOutcome<Result>

    private enum CodingKeys: String, CodingKey { case result, error }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if box.contains(.error) {
            outcome = .failure(try box.decode(RPCErrorObject.self, forKey: .error))
        } else {
            outcome = .value(try box.decode(Result.self, forKey: .result))
        }
    }
}

/// Облегчённый разбор конверта — только то, что нужно для маршрутизации уже распарсенного
/// (как JSON вообще, включая проверку повторяющихся ключей — `DomainJSON.decode` этой
/// структуры сам по себе уже несёт эту проверку) кадра: `schemaVersion` (строго, инв. 16),
/// `id` (наличие различает `response`/`notification`), `method` (нужен только
/// `notification`). Каждое поле — `try?`: если поле снятого типа не соответствует
/// (например, `schemaVersion` — строка), маршрутизация ниже трактует это как «отсутствует»,
/// и кадр всё равно получает `protocolViolation` — просто без чисел в сообщении.
struct RPCFramePeek: Decodable {
    let schemaVersion: Int?
    let id: Int?
    let method: String?

    private enum CodingKeys: String, CodingKey { case schemaVersion, id, method }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try? box.decodeBoundedIfPresent(Int.self, forKey: .schemaVersion)
        id = try? box.decodeBoundedIfPresent(Int.self, forKey: .id)
        method = try? box.decodeIfPresent(String.self, forKey: .method)
    }
}

/// Уведомления плагина (C-006 §6, «host/log»/«host/notify») — К47.
struct HostLogNotification: Decodable {
    struct Params: Decodable { let level: LogLevel; let message: String }
    let params: Params
}

struct HostNotifyNotification: Decodable {
    struct Params: Decodable { let kind: HostNotificationKind; let detail: String? }
    let params: Params
}

enum RPCErrorMapping {
    /// C-006 §5.1, первые две колонки таблицы отображения — код JSON-RPC → `ConnectorError`.
    /// Шесть строк «кода нет» (таймаут, смерть процесса, отменённый `Task`, ...) сюда не
    /// входят — у них нет кода на входе, отображает их не эта функция.
    static func connectorError(for error: RPCErrorObject) -> ConnectorError {
        switch error.code {
        case -32700, -32600, -32601, -32602, -32006:
            return .protocolViolation(message: error.message)
        case -32603:
            return .upstreamUnavailable(message: error.message)
        case -32001:
            return .authorizationRequired
        case -32002:
            return .notConfigured
        case -32003:
            return .rateLimited(retryAfterSeconds: leniateRetryAfterSeconds(error.retryAfterSecondsRaw))
        case -32004:
            return .cursorInvalid
        case -32005:
            return .upstreamUnavailable(message: error.message)
        case -32099 ... -32000:
            return .upstreamUnavailable(message: "нераспознанный код \(error.code): \(error.message)")
        default:
            return .protocolViolation(message: "код вне диапазона: \(error.code)")
        }
    }

    /// §5.2: годное значение — целое в `0...3600`. `CalendarPortImplCallWrapper.callConnector`
    /// уже трактует ЛЮБОЕ `retryAfterSeconds` вне `0...3600` как «нет годного значения,
    /// шаблонные задержки 1/2/4» — часовой вне диапазона (`-1`) даёт то же поведение без
    /// единой правки в `callConnector`.
    private static func leniateRetryAfterSeconds(_ raw: Double?) -> Int {
        guard let raw, raw.rounded(.towardZero) == raw, raw >= 0, raw <= 3600 else {
            return -1
        }
        return Int(raw)
    }
}
