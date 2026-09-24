//  Группа К (К66-К69, К71-К72) плана MEE-361: управляющая поверхность источника второго
//  возврата — stop() fan-out, отмена во время ожидания повтора, settingsSchema/configure/
//  healthCheck 1:1, первая дельта-синхронизация (Р9), calendarIds == selectedCalendarIds.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import CalendarHub

final class ControlSurfaceEntryPointsTests: XCTestCase {

    private let source = CalendarSourceId(rawValue: "src-1")

    // MARK: - К66 (stop() — fan-out shutdown всем инициализированным, ждёт всех)

    func test_k66_stopFansOutShutdownToAllInitializedSourcesAndAwaitsAll() async throws {
        let ids = ["src-1", "src-2", "src-3"]
        let harness = Harness(sourceIds: ids)
        let connectors = try await harness.seedAndInitialize(ids)

        let delayedConnector = connectors[2]
        delayedConnector.hang(.shutdown)

        let flag = DoneFlag()
        let stopTask = Task {
            await harness.hub.stop()
            await flag.markDone()
        }

        // Ждём, пока два незадержанных источника отработали shutdown — третий ещё висит на
        // воротах. НАЙДЕНО (бисекция CI-зависания, MEE-362 ч.2): без последнего условия —
        // `delayedConnector.callCount(.shutdown) > 0` — `release(.shutdown)` ниже мог уйти
        // ДО того, как вызов третьего источника вообще достиг `hangOrGate` (`group.addTask`
        // не гарантирует порядок старта дочерних задач): `release` без ожидающего продолжения —
        // no-op (см. его же комментарий в `FakeCalendarConnector`), а когда третий вызов
        // ПОЗЖЕ всё-таки встаёт в очередь, снять его уже некому — тот самый зависший
        // `swift test` на CI, найденный маркерами в stderr (сам тест START печатался,
        // ни одного теста дальше). Тот же приём, что `resolveTimeoutAfterHang`
        // (`InitializationTests.swift`) — ждать факта вызова (`callCount`), не просто
        // «соседи уже готовы».
        await pollUntil {
            connectors[0].shutdownCallCount > 0 && connectors[1].shutdownCallCount > 0
                && delayedConnector.callCount(.shutdown) > 0
        }
        let doneEarly = await flag.isDone()
        XCTAssertFalse(doneEarly, "stop() не возвращается, пока не отработал shutdown третьего источника")

        delayedConnector.release(.shutdown)
        await stopTask.value

        let doneAfterRelease = await flag.isDone()
        XCTAssertTrue(doneAfterRelease)
        for connector in connectors {
            XCTAssertEqual(connector.shutdownCallCount, 1)
        }
    }

    // MARK: - К67 (отмена во время ожидания повтора — cancelled, не transport)

    func test_k67_cancellationDuringRetryWaitGivesCancelledNotTransport() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.fail(.fetchEvents, with: .rateLimited(retryAfterSeconds: 5))

        let task = Task { await harness.hub.sync(trigger: .manual) }

        // Опрашиваем именно задержку ПОВТОРА (5с), не гонку таймаута fetchEvents (120с,
        // `raceTimeout`) — обе идут через один и тот же Ш3, различать по значению обязательно
        // (тот же довод, что у `resolveTimeoutAfterHang` в InitializationTests.swift).
        await pollUntil { harness.waitSeam.durations.contains(.seconds(5)) }
        task.cancel()

        let results = await task.value
        XCTAssertEqual(results.first?.failure, .cancelled, "не .transport, которым завершилось бы исчерпание повторов")
    }

    // MARK: - Два вызывающих на общей задаче (К35) — возврат РП, приёмка #94, п. 1

    /// (а) Второй вызывающий присоединяется к уже идущей `syncOne` (тот же источник, тот
    /// же `fetchEvents`, до этого не позванный вторично) и отменяется сам — первоначальная
    /// форма дефекта 8 (первый заход фикса п.1 отменял ОБЩУЮ задачу по отмене ОДНОГО
    /// вызывающего). Первый обязан дойти до настоящего результата как ни в чём не бывало.
    func test_syncOne_secondCallerCancellationDoesNotAffectFirst() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setFetchEvents([])
        connector.hang(.fetchEvents)

        let firstTask = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil { connector.callCount(.fetchEvents) > 0 }

        let secondTask = Task { await harness.hub.sync(trigger: .manual) }
        // Даём второму вызывающему шанс реально дойти до регистрации своего ожидания
        // (`syncWaiters`) до отмены — иначе отмена могла бы застать его ДО входа в
        // continuation и обойти как раз ту ветку, которую тест целится проверить (К35
        // не даёт внешнего наблюдаемого сигнала на сам факт регистрации).
        for _ in 0..<5 { await Task.yield() }
        secondTask.cancel()

        let secondResults = await secondTask.value
        XCTAssertEqual(secondResults.first?.failure, .cancelled, "второй вызывающий отменился — свой continuation")
        XCTAssertEqual(connector.callCount(.fetchEvents), 1, "второй присоединился к идущей задаче, не начал вторую")

        connector.release(.fetchEvents)
        let firstResults = await firstTask.value
        XCTAssertNil(firstResults.first?.failure, "отмена второго вызывающего не отменяет общую задачу за первого")
        XCTAssertEqual(connector.callCount(.fetchEvents), 1, "fetchEvents вызван ровно один раз на двоих вызывающих")
    }

    /// (б) Отменены ОБА вызывающих — последний уходящий обязан по-настоящему отменить общую
    /// задачу (тот же довод К67: отмена единственного оставшегося обязана прервать §5.2).
    func test_syncOne_cancellingBothCallersCancelsSharedTask() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.hang(.fetchEvents)

        let firstTask = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil { connector.callCount(.fetchEvents) > 0 }

        let secondTask = Task { await harness.hub.sync(trigger: .manual) }
        for _ in 0..<5 { await Task.yield() }

        firstTask.cancel()
        secondTask.cancel()

        let firstResults = await firstTask.value
        let secondResults = await secondTask.value
        XCTAssertEqual(firstResults.first?.failure, .cancelled)
        XCTAssertEqual(secondResults.first?.failure, .cancelled)

        // Общая задача действительно отменена — не осталась висеть на воротах fetchEvents
        // навсегда (`release(.fetchEvents)` тут ни разу не зовётся): отмена обязана дойти
        // до `hangOrGate` изнутри, тот отказывает через CancellationError, обобщённый catch
        // (дефект 4) пишет отказ через setSyncOutcome. Если бы общая задача не отменилась —
        // fetchEvents остался бы висеть вечно, и pollUntil упал бы явным таймаутом, не тихим
        // зависанием (тот же довод, что у resolveTimeoutAfterHang).
        await pollUntil { harness.connectorRepository.storedRecords.first?.lastError != nil }
    }

    // MARK: - К68 (settingsSchema/configure — 1:1 проброс)

    func test_k68_settingsSchemaAndConfigureProxy1to1() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))

        let schema = try await harness.hub.settingsSchema(source: source)
        XCTAssertEqual(schema, Data("{}".utf8), "байты connector.settingsSchema() без изменений")
        XCTAssertEqual(connector.callCount(.settingsSchema), 1)

        let settingsPayload = Data(#"{"key":"value"}"#.utf8)
        try await harness.hub.configure(source: source, settings: settingsPayload)
        XCTAssertEqual(
            connector.configureSettingsSeen, settingsPayload, "байты переданы как получены, без разбора/модификации"
        )
    }

    // MARK: - К69 (healthCheck — проброс результата как есть)

    func test_k69_healthCheckProxiesResultAsIs() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        let health = ConnectorHealth(
            status: .degraded, message: "slow", lastSuccessfulSyncAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        connector.setHealthCheck(health)

        let result = try await harness.hub.healthCheck(source: source)

        XCTAssertEqual(result, health, "status/message/lastSuccessfulSyncAt не переинтерпретируются")
        XCTAssertEqual(connector.callCount(.healthCheck), 1)
    }

    // MARK: - К71 (развилка Р9 — первая дельта-синхронизация)

    func test_k71_firstDeltaSyncFetchesChangesThenFullWindow() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: true, push: false, attendees: true, conference: true, auth: .none
        ))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let staleVersion = try Self.changingVersion("Stale", base: base, lastModified: base)
        let freshVersion = try Self.changingVersion("Fresh", base: base, lastModified: base.addingTimeInterval(60))
        connector.setFetchChanges(ChangeBatch(
            events: [staleVersion], deletedExternalIds: [], cursor: "cursor-1", resetRequired: false
        ))
        connector.setFetchEvents([freshVersion])

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure)
        XCTAssertEqual(connector.callCount(.fetchChanges), 1)
        XCTAssertEqual(connector.callCount(.fetchEvents), 1)
        XCTAssertTrue(
            connector.callLog.happened("CalendarConnector.fetchChanges", before: "CalendarConnector.fetchEvents"),
            "fetchChanges(cursor: nil) сначала, fetchEvents на полном окне Р2 — затем, тот же цикл"
        )
        XCTAssertEqual(harness.connectorRepository.storedRecords.first?.cursor, "cursor-1")

        // Различающий вектор: изменение между шагом 1 и шагом 2 — шаг 2 (полный fetchEvents,
        // выполненный позже) видит его в актуальном виде, независимо от ответа шага 1.
        let stored = try await harness.hub.events(
            from: base.addingTimeInterval(-60), to: base.addingTimeInterval(3_600)
        )
        XCTAssertEqual(stored.first { $0.externalId == "evt-changing" }?.title, "Fresh")

        // Отдельный вход: следующая синхронизация (курсор уже есть) — только fetchChanges.
        connector.setFetchChanges(ChangeBatch(
            events: [], deletedExternalIds: [], cursor: "cursor-2", resetRequired: false
        ))
        _ = await harness.hub.sync(trigger: .manual)
        XCTAssertEqual(connector.callCount(.fetchChanges), 2)
        XCTAssertEqual(
            connector.callCount(.fetchEvents), 1, "fetchEvents не вызван на цикле с уже существующим курсором"
        )
    }

    /// Возврат РП, приёмка #94, п. 3 — ветка ошибки дефекта 1 (приёмка #85): если шаг 1
    /// (`fetchChanges(nil)`) отработал, а шаг 2 (полное окно) упал, курсор шага 1 не
    /// сохраняется вовсе — следующий цикл видит `cursor == nil` и снова идёт по Р9 целиком
    /// (`fetchChanges` + `fetchEvents`), а не по `applyDeltaSync` с уже якобы годным
    /// курсором, за которым полное окно не загрузилось бы никогда.
    func test_k71_fullWindowFailureLeavesCursorNilSoNextCycleRetriesFullWindow() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: true, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setFetchChanges(ChangeBatch(
            events: [], deletedExternalIds: [], cursor: "cursor-1", resetRequired: false
        ))
        connector.fail(.fetchEvents, with: .protocolViolation(message: "полное окно недоступно"))

        let firstResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNotNil(firstResults.first?.failure, "полное окно упало — цикл обязан отразить отказ")
        XCTAssertNil(
            harness.connectorRepository.storedRecords.first?.cursor,
            "курсор шага 1 не сохраняется, пока полное окно не завершилось успешно"
        )

        connector.clearFailure(.fetchEvents)
        connector.setFetchEvents([])
        connector.setFetchChanges(ChangeBatch(
            events: [], deletedExternalIds: [], cursor: "cursor-2", resetRequired: false
        ))
        let secondResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(secondResults.first?.failure)
        XCTAssertEqual(connector.callCount(.fetchChanges), 2, "курсора после первого отказа не было — снова шаг 1")
        XCTAssertEqual(connector.callCount(.fetchEvents), 2, "снова полное окно, не только дельта")
        XCTAssertEqual(harness.connectorRepository.storedRecords.first?.cursor, "cursor-2")
    }

    /// Возврат РП, приёмка #94, п. 4 — дефект 4 (приёмка #85): ошибка, которая НЕ
    /// `CalendarError` (здесь — `StorageError` из `meetingRepository.save`, дошедшая через
    /// `applyIncoming`/`applyFullWindow`), обязана попасть в `setSyncOutcome` тем же путём,
    /// что и ветка `CalendarError` — запись коннектора не должна остаться с `lastError == nil`
    /// только потому, что упавший тип не `CalendarError`.
    func test_defect4_nonCalendarErrorStillReachesSetSyncOutcome() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        connector.setFetchEvents([try Self.changingVersion("Title", base: base, lastModified: base)])
        harness.meetingRepository.fail(with: .io(message: "диск недоступен"), on: .save)

        let results = await harness.hub.sync(trigger: .manual)

        guard case .transport = results.first?.failure else {
            XCTFail("не-CalendarError обязан отобразиться как .transport, не проглатываться молча")
            return
        }
        XCTAssertNotNil(
            harness.connectorRepository.storedRecords.first?.lastError,
            "дефект 4: обобщённая ветка catch обязана писать setSyncOutcome с ошибкой, как и ветка CalendarError"
        )
    }

    // MARK: - К72 (calendarIds == selectedCalendarIds, не полный список и не литерал теста)

    func test_k72_calendarIdsArgumentIsSelectedCalendarIdsNotFullList() async throws {
        // Вектор fetchEvents (deltaSync == false).
        let fullWindowHarness = Harness(sourceIds: ["src-1"])
        fullWindowHarness.connectorRepository.seed([
            Harness.record(id: "src-1", selectedCalendarIds: ["cal-1", "cal-3"])
        ])
        let fullWindowConnector = fullWindowHarness.connector("src-1")
        fullWindowConnector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        fullWindowConnector.setFetchEvents([])
        _ = await fullWindowHarness.hub.sync(trigger: .manual)
        let fetchEventsCall = fullWindowConnector.callLog.calls(port: "CalendarConnector")
            .last { $0.method == "fetchEvents" }
        guard let call = fetchEventsCall else { XCTFail("fetchEvents не вызван"); return }
        XCTAssertEqual(Array(call.arguments.suffix(2)), ["cal-1", "cal-3"])

        // Вектор fetchChanges (deltaSync == true, курсор уже есть) — отдельный harness, чтобы
        // не напороться на кэш capabilities первого источника (initialize только один раз, К7).
        let deltaHarness = Harness(sourceIds: ["src-1"])
        deltaHarness.connectorRepository.seed([
            Harness.record(id: "src-1", cursor: "cursor-x", selectedCalendarIds: ["cal-1", "cal-3"])
        ])
        let deltaConnector = deltaHarness.connector("src-1")
        deltaConnector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: true, push: false, attendees: true, conference: true, auth: .none
        ))
        deltaConnector.setFetchChanges(ChangeBatch(
            events: [], deletedExternalIds: [], cursor: "cursor-y", resetRequired: false
        ))
        _ = await deltaHarness.hub.sync(trigger: .manual)
        let fetchChangesCall = deltaConnector.callLog.calls(port: "CalendarConnector")
            .last { $0.method == "fetchChanges" }
        guard let changesCall = fetchChangesCall else { XCTFail("fetchChanges не вызван"); return }
        XCTAssertEqual(Array(changesCall.arguments.suffix(2)), ["cal-1", "cal-3"])
    }

    // MARK: - Оснастка

    private static func changingVersion(_ title: String, base: Date, lastModified: Date) throws -> MeetingEventPayload {
        try MeetingEventPayload(
            sourceConnectorId: "eventkit", externalId: "evt-changing", icalUid: nil, title: title,
            start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
            isCancelled: false, organizer: nil, attendees: [], location: nil, bodyText: nil,
            conference: nil, lastModified: lastModified
        )
    }
}
