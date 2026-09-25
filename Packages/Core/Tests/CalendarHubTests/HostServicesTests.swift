//  Группа Б (К11-К14, К61) плана MEE-361: сервисы хоста коннектору — секреты, лог,
//  уведомление. К61 (часть 3и, MEE-386) — уведомление → внутренняя syncOne (развилка Р6).
//
//  ЧТО ЭТА ПРАВКА НЕ ПОКРЫВАЕТ ЗДЕСЬ, ЧЕСТНО:
//  * К12 — целиком: сформулирован для stdio-пути («не более одного запроса в очереди» —
//    свойство кадров `request`/`response` C-006 §2, у in-process вызова их попросту нет).
//    Шов Ш2 (`RPCTransport`/`ScriptedRPCTransport`, `StdioCalendarConnector`) написан МЕЕ-402
//    шагом 2 (`StdioProtocolTests.swift`, К46-К56) — сам тест К12 всё ещё нет, следующая
//    часть MEE-386.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class HostServicesTests: XCTestCase {

    private let source = CalendarSourceId(rawValue: "src-1")

    // MARK: - К11 (секреты — Ш1, namespace == connectorInstanceId)

    func test_k11_secretsNamespacedByConnectorInstanceId() async throws {
        let harness = Harness(sourceIds: ["eventkit-1", "eventkit-2"])
        harness.connectorRepository.seed([Harness.record(id: "eventkit-1"), Harness.record(id: "eventkit-2")])
        let connector1 = harness.connector("eventkit-1")
        let connector2 = harness.connector("eventkit-2")
        for connector in [connector1, connector2] {
            connector.setInitializeResult(capabilities: ConnectorCapabilities(
                deltaSync: false, push: false, attendees: true, conference: true, auth: .none
            ))
        }

        _ = try await harness.hub.listCalendars(source: CalendarSourceId(rawValue: "eventkit-1"))
        _ = try await harness.hub.listCalendars(source: CalendarSourceId(rawValue: "eventkit-2"))
        guard let host1 = connector1.lastHost, let host2 = connector2.lastHost else {
            XCTFail("initialize не захватил host")
            return
        }

        try await host1.secretSet(key: "refreshToken", value: "token-1")
        try await host2.secretSet(key: "refreshToken", value: "token-2")

        XCTAssertEqual(
            harness.secretStore.recordedCalls.filter { $0.namespace == "eventkit-1" }.map(\.key), ["refreshToken"]
        )
        XCTAssertEqual(
            harness.secretStore.recordedCalls.filter { $0.namespace == "eventkit-2" }.map(\.key), ["refreshToken"]
        )

        // Различающий вектор: тот же ключ, разные namespace — секреты не пересекаются.
        let value1 = try await host1.secretGet(key: "refreshToken")
        let value2 = try await host2.secretGet(key: "refreshToken")
        XCTAssertEqual(value1, "token-1")
        XCTAssertEqual(value2, "token-2")

        // secretSet(value: nil) удаляет запись, не пишет пустую строку.
        try await host1.secretSet(key: "refreshToken", value: nil)
        let clearedValue1 = try await host1.secretGet(key: "refreshToken")
        XCTAssertNil(clearedValue1)
        let stillValue2 = try await host2.secretGet(key: "refreshToken")
        XCTAssertEqual(stillValue2, "token-2", "удаление у первого источника не задело второй")
    }

    // MARK: - К13 (in-process — брошенный Error, не смерть процесса)

    func test_k13_inProcessThrowNotProcessDeath() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.fail(.fetchEvents, with: .protocolViolation(message: "произвольная ошибка коннектора"))

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(
            results.first?.failure,
            .protocolViolation(sourceId: source, message: "произвольная ошибка коннектора"),
            "отображена таблицей §5.1 (К54), той же, что и stdio-путь"
        )
        // Не смерть процесса: тот же источник снова доступен следующим циклом без initialize
        // заново (capabilities не сброшены — только upstreamUnavailable/timeout это делают,
        // К10/Р10, К9) — сама Task/актор пережили брошенную ошибку.
        connector.clearFailure(.fetchEvents)
        connector.setFetchEvents([])
        let secondResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(secondResults.first?.failure)
        XCTAssertEqual(connector.callCount(.initialize), 1, "капабилities пережили ошибку — не переинициализировано")
    }

    // MARK: - К14 (лог: наблюдаемая часть + мех. сигнатура)

    func test_k14_logCapturesLevelAndMessage() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setListCalendars([])
        _ = try await harness.hub.listCalendars(source: source)
        guard let host = connector.lastHost else {
            XCTFail("initialize не захватил host")
            return
        }

        // `log(_:_:)` не async — запись в состояние актора идёт через Task внутри
        // HostServicesImpl (см. его шапку); опрашиваем, а не await, синхронизирующей ручки
        // здесь контрактом не предусмотрено (не то же самое, что MEE-365 — там был свой
        // тестовый крюк, здесь наблюдаемая сторона не даёт такого же прямого доступа).
        host.log(.error, "проверочное сообщение")
        await pollUntil { await !harness.hub.loggedEntries(for: source).isEmpty }

        let entries = await harness.hub.loggedEntries(for: source)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.level, .error)
        XCTAssertEqual(entries.first?.message, "проверочное сообщение")
    }

    /// Мех.: `log(_:_:)` в `ConnectorHostServices` не несёт `async`/`throws` — компилятор сам
    /// не пропустил бы `HostServicesImpl.log` иначе (протокол обязывает совпадение подписи).
    /// Возврат РП по MEE-347: «не блокирует вызывающего» в рантайм-смысле не наблюдаемо для
    /// не-`async` функции — прежний вектор проверял недоказуемое, этот фиксирует текст
    /// контракта, чтобы будущая правка сигнатуры не прошла незамеченной мимо теста.
    func test_k14_logSignatureIsSyncNonThrowing() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DomainCore/ConnectorHost.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            text.contains("func log(_ level: LogLevel, _ message: String)"),
            "log(_:_:) обязана оставаться синхронной, без throws — иначе «не блокирует вызывающего» " +
            "перестаёт быть гарантией компилятора"
        )
    }

    // MARK: - К61 (уведомление → внутренняя syncOne, развилка Р6)

    /// Вход: источник с `capabilities.push == true` вызывает `notify(.changesAvailable,
    /// detail: nil)`. Ответ: хост вызывает внутреннюю `syncOne(source:trigger: .push)` для
    /// ИМЕННО этого источника, немедленно и напрямую — различающий вектор против публичного
    /// `sync(trigger:)` (у которого нет параметра источника): второй, не уведомленный
    /// источник остаётся нетронутым.
    /// Возврат РП (приёмка #129, п. 2): прежняя версия проверяла `src-2 == 0` СРАЗУ после
    /// `pollUntil { src-1.fetchEvents > 0 }` — публичный `sync` обходит источники
    /// параллельно, так что этот момент не доказывает, что push-синхронизация вообще
    /// успела завершиться, только что она НАЧАЛАСЬ; ложноположительный проход возможен,
    /// если баг всё-таки трогает src-2 чуть ПОЗЖЕ этой проверки. Фикс — не полагаться на
    /// момент, а присоединиться к уже идущей задаче СВОИМ `syncOne(source:trigger: .push)`
    /// (тот же приём, что К35) и дождаться `joined.value`: это гарантированно наступает
    /// только ПОСЛЕ того, как исходная задача полностью завершилась (`finishInFlightSync`
    /// рассылает результат всем ожидающим разом) — src-2 проверяется уже после этого
    /// момента, не раньше. Заодно `result.trigger` — различающий вектор: если бы
    /// `handleNotify` дёрнул `syncOne` с другим триггером (не `.push`), общий результат
    /// нёс бы ЕГО, не `.push` (мой собственный параметр `.push` тут не решает — я
    /// ПРИСОЕДИНЯЮСЬ к чужой уже стартовавшей задаче, не завожу свою).
    func test_k61_changesAvailableTriggersDirectSyncOneNotPublicSync() async throws {
        let harness = Harness(sourceIds: ["src-1", "src-2"])
        harness.connectorRepository.seed([Harness.record(id: "src-1"), Harness.record(id: "src-2")])
        for id in ["src-1", "src-2"] {
            harness.connector(id).setInitializeResult(capabilities: ConnectorCapabilities(
                deltaSync: false, push: true, attendees: true, conference: true, auth: .none
            ))
            harness.connector(id).setFetchEvents([])
        }
        let source1 = CalendarSourceId(rawValue: "src-1")
        _ = try await harness.hub.listCalendars(source: source1)
        _ = try await harness.hub.listCalendars(source: CalendarSourceId(rawValue: "src-2"))
        guard let host1 = harness.connector("src-1").lastHost else {
            XCTFail("initialize не захватил host")
            return
        }
        harness.connector("src-1").hang(.fetchEvents)

        host1.notify(.changesAvailable, detail: nil)
        await pollUntil { harness.connector("src-1").callCount(.fetchEvents) > 0 }
        let joined = Task { await harness.hub.syncOne(source: source1, trigger: .push) }
        await pollUntil { await harness.hub.syncWaiters[source1]?.count == 2 }
        harness.connector("src-1").release(.fetchEvents)
        let result = await joined.value

        XCTAssertEqual(result.trigger, .push, "notify(.changesAvailable) дёргает syncOne именно с .push")
        XCTAssertEqual(harness.connector("src-1").callCount(.fetchEvents), 1, "join не завёл вторую синхронизацию")
        XCTAssertEqual(
            harness.connector("src-2").callCount(.fetchEvents), 0,
            "не публичный sync(trigger:) — тот обошёл бы ВСЕ источники, syncOne трогает только src-1"
        )
    }

    /// Отдельный вход: `notify(.authExpired)`/`notify(.configInvalid)` — не вызывают ни
    /// `syncOne`, ни `sync`; фиксируются тем же перехватчиком, что К14 (`recordedNotifications`
    /// рядом с `loggedEntries`), для последующего чтения хостом.
    ///
    /// Возврат РП (найдено main-ом красным после слияния #129, приёмка, 00:35 UTC):
    /// прежняя версия сравнивала `entries.map(\.kind)` С ПОРЯДКОМ — `[.authExpired,
    /// .configInvalid]`. `HostServicesImpl.notify(_:detail:)` заводит СВОЙ независимый
    /// `Task { await hub.handleNotify(...) } на каждый вызов (см. его шапку — так и
    /// задумано, «не блокирует вызывающего», К14) — порядок доставки между ДВУМЯ
    /// независимыми `Task` ничем не гарантирован, это не дефект реализации: ни C-006, ни
    /// К14/К61 не обещают последовательную доставку notify() между разными вызовами (в
    /// отличие, например, от К62/К63, где порядок потока `changes()` — прямая цитата
    /// контракта). Правильная проверка — оба уведомления присутствуют с верным `detail`,
    /// не в каком порядке.
    func test_k61_authExpiredAndConfigInvalidAreRecordedNotSynced() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        harness.connector("src-1").setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        _ = try await harness.hub.listCalendars(source: source)
        guard let host = harness.connector("src-1").lastHost else {
            XCTFail("initialize не захватил host")
            return
        }

        host.notify(.authExpired, detail: nil)
        host.notify(.configInvalid, detail: "bad config")
        await pollUntil { await harness.hub.recordedNotifications(for: source).count == 2 }

        let entries = await harness.hub.recordedNotifications(for: source)
        XCTAssertEqual(Set(entries.map(\.kind)), [.authExpired, .configInvalid], "оба уведомления записаны")
        XCTAssertTrue(entries.contains { $0.kind == .authExpired && $0.detail == nil })
        XCTAssertTrue(entries.contains { $0.kind == .configInvalid && $0.detail == "bad config" })
        XCTAssertEqual(harness.connector("src-1").callCount(.fetchEvents), 0, "не вызывают ни syncOne, ни sync")
    }
}
