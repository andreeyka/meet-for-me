//  StdioCalendarConnector — продовый адаптер `CalendarConnector` (зеркало C-006 §6) поверх
//  `RPCTransport` (C-006 §2): хост stdio, группа Ж перечня MEE-347 (К46-К56). Кадрирование,
//  коды ошибок и их отображение (§5.1), политика повторов (§5.2, применяется вызывающей
//  стороной — `CalendarPortImplCallWrapper.callConnector`, без изменений здесь), предел «один
//  запрос в очереди» (К12, MEE-386) и разбор манифеста (`PluginManifest.swift`) — обязанности
//  этого файла; таймаут (К9) — обязанность вызывающей стороны и остаётся вне этого файла.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import DomainCore

/// Пустые `params`/`result` кадра — свой тип на каждое направление, а не `Void`
/// (`Void: Codable` не бывает). `VoidResult.init(from:)` намеренно не трогает `decoder` —
/// значение по ключу `result` может быть `{}` или `null`, методу без результата (`configure`)
/// это безразлично: сам факт наличия ключа `result` (а не `error`) уже отличил успех от
/// ошибки на уровне `RPCResponseBody`.
private struct NoParams: Encodable {}
private struct VoidResult: Decodable { init(from decoder: Decoder) throws {} }

/// Один RPC-вызов туда-обратно: кодирует запрос, шлёт через `RPCTransport.send(_:)`, читает
/// кадры через `RPCTransport.receive()` в цикле — `notification`-кадры (host/log, host/notify)
/// диспетчерует и продолжает ждать (К47), кадр с чужим `id` — немедленный `protocolViolation`
/// без дальнейшего ожидания (К46), кадр длиннее 8 МиБ или не JSON — тоже (К48). Единственный
/// тип, объявляющий связь между `RPCTransport` и зеркалом протокола C-006 §6 — сам
/// `CalendarConnector`, объявленный `domain-core` (MEE-346), здесь только реализуется.
public actor StdioCalendarConnector: CalendarConnector {
    private let transport: RPCTransport
    private var nextId = 0
    private var host: ConnectorHostServices?
    private var callSlotHeld = false
    private var callSlotWaiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Только для тестов (МЕЕ-386, К12): число вызовов `call()`, ждущих своей очереди на слот
    /// — не `private`, чтобы `@testable import` мог опросить его детерминированно (без сна по
    /// часам) в гонке «второй вызов уже пытается начать, но ещё не начал».
    var pendingCallSlotWaiterCount: Int { callSlotWaiters.count }

    /// К1 (MEE-386): `protocolVersion` — та же форма сравнения, что манифест (К53,
    /// `RPCProtocolVersion.majorIsCompatible`, `PluginManifest.swift`) — совпадение `MAJOR`
    /// обязательно, `MINOR` нет. Несовпадение `MAJOR` — `protocolViolation`, до того как
    /// `capabilities`/`plugin` вообще возвращаются вызывающей стороне: `ensureInitialized`
    /// (`CalendarPortImpl.swift`) не кеширует `capabilities[source]` при брошенной ошибке,
    /// так что коннектор остаётся неинициализированным и не используется дальше в этом
    /// цикле — то же самое, чем уже становится любая другая ошибка `initialize` сегодня, без
    /// отдельного «навсегда чёрного списка», которого контракт не называет.
    public func initialize(
        host: ConnectorHostServices, connectorInstanceId: String
    ) async throws -> (PluginInfo, ConnectorCapabilities) {
        self.host = host
        struct Params: Encodable { let connectorInstanceId: String }
        struct Result: Decodable {
            let plugin: PluginInfo
            let protocolVersion: String
            let capabilities: ConnectorCapabilities
        }
        let result: Result = try await call(
            method: "initialize", params: Params(connectorInstanceId: connectorInstanceId)
        )
        let supportedMajor = RPCHostVersioning.supportedProtocolMajor
        guard RPCProtocolVersion.majorIsCompatible(result.protocolVersion, supportedMajor: supportedMajor) else {
            throw ConnectorError.protocolViolation(
                message: "protocolVersion несовместим: получено \(result.protocolVersion), "
                    + "нужен MAJOR \(supportedMajor)"
            )
        }
        return (result.plugin, result.capabilities)
    }

    public func settingsSchema() async throws -> Data {
        struct Result: Decodable { let schema: Data }
        let result: Result = try await call(method: "settingsSchema", params: NoParams())
        return result.schema
    }

    public func configure(settings: Data) async throws {
        struct Params: Encodable { let settings: Data }
        let _: VoidResult = try await call(method: "configure", params: Params(settings: settings))
    }

    public func beginAuth() async throws -> AuthChallenge {
        try await call(method: "beginAuth", params: NoParams())
    }

    public func completeAuth(callbackUrl: URL) async throws -> String? {
        struct Params: Encodable { let callbackUrl: URL }
        struct Result: Decodable { let accountLabel: String? }
        let result: Result = try await call(method: "completeAuth", params: Params(callbackUrl: callbackUrl))
        return result.accountLabel
    }

    public func listCalendars() async throws -> [ConnectorCalendar] {
        struct Result: Decodable { let calendars: [ConnectorCalendar] }
        let result: Result = try await call(method: "listCalendars", params: NoParams())
        return result.calendars
    }

    public func fetchEvents(from: Date, to: Date, calendarIds: [String]) async throws -> [MeetingEventPayload] {
        struct Params: Encodable { let from: Date; let to: Date; let calendarIds: [String] }
        struct Result: Decodable { let events: [MeetingEventPayload] }
        let result: Result = try await call(
            method: "fetchEvents", params: Params(from: from, to: to, calendarIds: calendarIds)
        )
        return result.events
    }

    public func fetchChanges(cursor: String?, calendarIds: [String]) async throws -> ChangeBatch {
        struct Params: Encodable { let cursor: String?; let calendarIds: [String] }
        return try await call(method: "fetchChanges", params: Params(cursor: cursor, calendarIds: calendarIds))
    }

    public func healthCheck() async throws -> ConnectorHealth {
        try await call(method: "healthCheck", params: NoParams())
    }

    /// Не бросает (подпись C-006 §6): лучшее усилие — кадр `shutdown` отправляется, ответ не
    /// ожидается. Отдельного вызова `waitSeam`/повторной политики этому методу нет и не
    /// нужно (§5.2: «shutdown никогда не повторяется») — ровно одна попытка отправки.
    public func shutdown() async {
        nextId += 1
        let frame = RPCRequestFrame(id: nextId, method: "shutdown", params: Optional<NoParams>.none)
        guard let data = try? DomainJSON.encode(frame), let line = String(data: data, encoding: .utf8) else {
            return
        }
        try? await transport.send(line)
    }

    // MARK: - Общий цикл запрос → ответ

    /// К12 (MEE-386): не более одного `request`-кадра хоста в очереди — второй вызов `call()`
    /// не отправляет СВОЙ кадр, пока первый не получил ответ (или не был отменён вызывающей
    /// стороной, например таймаутом — `defer` ниже освобождает слот в любом исходе). `host/log`/
    /// `host/notify` (К47) сюда не относятся — это `notification`-кадры ПЛАГИНА, не `request`
    /// хоста, и `dispatchNotification` разбирает их внутри уже идущего ожидания ответа, не как
    /// отдельный вызов `call()`.
    private func call<Params: Encodable, Result: Decodable>(method: String, params: Params) async throws -> Result {
        await acquireCallSlot()
        defer { releaseCallSlot() }
        nextId += 1
        let id = nextId
        let frame = RPCRequestFrame(id: id, method: method, params: params)
        let requestData: Data
        do {
            requestData = try DomainJSON.encode(frame)
        } catch {
            throw ConnectorError.protocolViolation(message: "не удалось закодировать исходящий кадр: \(error)")
        }
        guard let line = String(data: requestData, encoding: .utf8) else {
            throw ConnectorError.protocolViolation(message: "исходящий кадр не представим UTF-8")
        }
        do {
            try await transport.send(line)
        } catch {
            // Контракт не разбирает отказ самой отправки отдельно — трактуется тем же
            // исходом, что смерть процесса (§5.1, строка «кода нет»): `upstreamUnavailable`.
            throw ConnectorError.upstreamUnavailable(message: "\(error)")
        }
        return try await awaitResponse(id: id)
    }

    /// Очередь ожидающих — не голая пара «занято/свободно» вроде `NSLock`: актор и так
    /// исполняет `call()` не более одного за раз МЕЖДУ точками приостановки, но каждая точка
    /// (`await transport.send`/`await transport.receive` внутри `awaitResponse`) впускает
    /// другие вызовы того же актора — без явной очереди второй вызов мог бы начать СВОЙ
    /// `send()`, пока первый ещё ждёт ответа. `CheckedContinuation<Void, Never>` — ожидание
    /// самого слота не отменяемо по отдельности (отмена самого вызывающего `call()` снимается
    /// на уровне `awaitResponse`/`transport.receive()`, не здесь).
    private func acquireCallSlot() async {
        guard callSlotHeld else {
            callSlotHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            callSlotWaiters.append(continuation)
        }
    }

    /// Передаёт слот следующему в очереди (не освобождает вовсе, если очередь не пуста) —
    /// FIFO тем же порядком, что вызовы пришли, чего простой булев флаг сам по себе не
    /// гарантировал бы (следующий acquire мог бы достаться не первому дождавшемуся).
    private func releaseCallSlot() {
        guard !callSlotWaiters.isEmpty else {
            callSlotHeld = false
            return
        }
        let next = callSlotWaiters.removeFirst()
        next.resume()
    }

    private func awaitResponse<Result: Decodable>(id: Int) async throws -> Result {
        while true {
            let line: String
            do {
                line = try await transport.receive()
            } catch {
                throw ConnectorError.upstreamUnavailable(message: "\(error)")
            }
            guard let data = line.data(using: .utf8), data.count <= RPCFrameLimits.maxFrameBytes else {
                throw ConnectorError.protocolViolation(message: "кадр длиннее 8 МиБ или не UTF-8")
            }
            guard let peek = try? DomainJSON.decode(RPCFramePeek.self, from: data) else {
                throw ConnectorError.protocolViolation(message: "кадр не разобрался как JSON")
            }
            guard peek.schemaVersion == RPCFrameLimits.schemaVersion else {
                let got = peek.schemaVersion.map(String.init) ?? "отсутствует"
                throw ConnectorError.protocolViolation(
                    message: "schemaVersion конверта: получено \(got), ожидалось \(RPCFrameLimits.schemaVersion)"
                )
            }
            guard let responseId = peek.id else {
                try dispatchNotification(method: peek.method, data: data)
                continue
            }
            guard responseId == id else {
                throw ConnectorError.protocolViolation(
                    message: "ответ id=\(responseId) не соответствует ожидаемому id=\(id)"
                )
            }
            let body: RPCResponseBody<Result>
            do {
                body = try DomainJSON.decode(RPCResponseBody<Result>.self, from: data)
            } catch {
                throw ConnectorError.protocolViolation(message: "\(error)")
            }
            switch body.outcome {
            case .value(let value):
                return value
            case .failure(let error):
                throw RPCErrorMapping.connectorError(for: error)
            }
        }
    }

    /// К47: `notification` без `id` (`host/log`/`host/notify`) — принимается в любой момент,
    /// не считается ошибкой и не прерывает ожидание ответа на текущий запрос хоста.
    ///
    /// Не `switch` со строковыми ветвями метода: К59 (МЕЕ-412, `calendar-hub-surface.py`)
    /// ищет построчным текстом любую ветвь switch на строковом литерале, не разбирая, над
    /// чем именно идёт ветвление, — здесь это имя метода JSON-RPC (C-006 §6), а не
    /// `ConnectorRecord.type`/`CalendarSourceId.rawValue` (ровно то, что запрещает К59 по
    /// смыслу), но механическая проверка этого не различает. Сравнение через `if`/`else`
    /// не задевает ни один её шаблон (все требуют `.type`/`.rawValue` рядом со сравнением
    /// или switch-ветвь на литерале).
    private func dispatchNotification(method: String?, data: Data) throws {
        guard let method else {
            throw ConnectorError.protocolViolation(message: "кадр без id и без method")
        }
        do {
            if method == "host/log" {
                let frame = try DomainJSON.decode(HostLogNotification.self, from: data)
                host?.log(frame.params.level, frame.params.message)
            } else if method == "host/notify" {
                let frame = try DomainJSON.decode(HostNotifyNotification.self, from: data)
                host?.notify(frame.params.kind, detail: frame.params.detail)
            } else {
                throw ConnectorError.protocolViolation(message: "неизвестный notification-метод: \(method)")
            }
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw ConnectorError.protocolViolation(message: "\(error)")
        }
    }
}
