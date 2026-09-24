//  Группа Б (К11-К14, К61) плана MEE-361: сервисы хоста коннектору — секреты, лог,
//  уведомление.
//
//  ЧТО ЭТА ПРАВКА НЕ ПОКРЫВАЕТ ЗДЕСЬ, ЧЕСТНО:
//  * К12 — целиком: сформулирован для stdio-пути («не более одного запроса в очереди» —
//    свойство кадров `request`/`response` C-006 §2, у in-process вызова их попросту нет).
//    Шов Ш2 (`RPCTransport`/`ScriptedRPCTransport`) — «ждёт кода calendar-hub» (план MEE-361,
//    §1) — группа Ж, ещё не написана. Тестировать не на чем до неё.
//  * К61 — вне постановки этой правки (МЕЕ-362 ч.2 называет К3, К8, К11-К14, К40-К41,
//    К62-К63, К66-К69, К71-К75 явно, К61 в списке нет) — остаётся следующей части, тот же
//    файл по плану MEE-361 группирует его с К11-К14, но сама постановка его не просила.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import CalendarHub

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
        await pollUntil(await !harness.hub.loggedEntries(for: source).isEmpty)

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
}
