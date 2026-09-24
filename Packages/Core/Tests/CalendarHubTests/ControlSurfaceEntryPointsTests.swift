//  Группа К (К66-К69, К71-К72) плана MEE-361: управляющая поверхность источника второго
//  возврата — stop() fan-out, отмена во время ожидания повтора, settingsSchema/configure/
//  healthCheck 1:1, первая дельта-синхронизация (Р9), calendarIds == selectedCalendarIds.
//
//  Возврат РП (MEE-386, 19:08 UTC): SwiftLint `type_body_length` (класс — 264 строки кода
//  без комментариев/пустых строк, предел 250) — К68/К69/К71/К72 и дефект 4, вместе с их
//  оснасткой (`changingVersion`), вынесены в `ControlSurfaceHostProxyTests.swift` тем же
//  приёмом, каким уже разведены `CalendarPortImplSync.swift`/`CalendarPortImplMerge.swift`:
//  `extension` того же класса в отдельном файле — SwiftLint считает КАЖДОЕ расширение типа
//  отдельно. Логика тестов не менялась — только перемещение кода.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class ControlSurfaceEntryPointsTests: XCTestCase {

    let source = CalendarSourceId(rawValue: "src-1")

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

    /// Дефект 3 (MEE-362 ч.3/MEE-386, `stop()`): раньше `shutdown()` без таймаута могло
    /// повесить `stop()` НАВСЕГДА на зависшем коннекторе — единственным способом снять его
    /// был `release(.shutdown)` теста, будто ждать реальный процесс было некому. Здесь
    /// `connector.shutdown()` НИКОГДА не отпускается (без `release`, в отличие от теста
    /// выше) — единственный способ, которым `stop()` может вернуться, — таймаут `waitSeam`
    /// (`shutdownWithTimeout`, К9 `.other`/30с). `pollUntil { waitSeam.resolveNext() }` —
    /// тот же приём, что `resolveTimeoutAfterHang` (`InitializationTests.swift`): не отпускает
    /// ворота раньше, чем гонка реально в них встала.
    func test_defect3_stopReturnsOnShutdownTimeoutEvenIfConnectorNeverReturns() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        let connectors = try await harness.seedAndInitialize(["src-1"])
        let connector = connectors[0]
        connector.hang(.shutdown)

        let flag = DoneFlag()
        let stopTask = Task {
            await harness.hub.stop()
            await flag.markDone()
        }

        await pollUntil { connector.callCount(.shutdown) > 0 }
        let doneBeforeTimeout = await flag.isDone()
        XCTAssertFalse(
            doneBeforeTimeout, "stop() не должен вернуться раньше — ни shutdown, ни таймаут ещё не отработали"
        )

        await pollUntil { harness.waitSeam.resolveNext() }
        await stopTask.value

        let done = await flag.isDone()
        XCTAssertTrue(
            done, "stop() обязан вернуться по таймауту, даже если connector.shutdown() никогда не возвращается"
        )
        XCTAssertEqual(connector.shutdownCallCount, 1)
        XCTAssertTrue(
            harness.waitSeam.durations.contains(.seconds(30)), "гонка идёт с тем же пределом .other, что К68/К73"
        )
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
        // Возврат РП: ждём ФАКТ регистрации второго в syncWaiters (внутреннее состояние,
        // `@testable import`), не гонку с yield — иначе отмена могла бы застать его ДО
        // входа в continuation (guard !Task.isCancelled, CalendarPortImplSync.swift) и
        // обойти как раз ту ветку, которую тест целится проверить: оба вызывающих тогда
        // проходят, ничего не проверив на самом деле.
        await pollUntil { await harness.hub.syncWaiters[source]?.count == 2 }
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
        // Тот же довод, что в (а): ждём факт регистрации второго в syncWaiters, не гонку
        // с yield.
        await pollUntil { await harness.hub.syncWaiters[source]?.count == 2 }

        firstTask.cancel()
        secondTask.cancel()

        let firstResults = await firstTask.value
        let secondResults = await secondTask.value
        XCTAssertEqual(firstResults.first?.failure, .cancelled)
        XCTAssertEqual(secondResults.first?.failure, .cancelled)
        XCTAssertEqual(connector.callCount(.fetchEvents), 1, "общая задача была ровно одна — один fetchEvents на двоих")

        // Общая задача действительно отменена — не осталась висеть на воротах fetchEvents
        // навсегда (`release(.fetchEvents)` тут ни разу не зовётся): отмена обязана дойти
        // до `hangOrGate` изнутри, тот отказывает через CancellationError, обобщённый catch
        // (дефект 4) пишет отказ через setSyncOutcome. Если бы общая задача не отменилась —
        // fetchEvents остался бы висеть вечно, и pollUntil упал бы явным таймаутом, не тихим
        // зависанием (тот же довод, что у resolveTimeoutAfterHang).
        await pollUntil { harness.connectorRepository.storedRecords.first?.lastError != nil }
    }

    // MARK: - Два пограничных случая отмены из #94 (бэклог MEE-386, возврат РП 19:25 UTC)
    //
    // Оба теста подвешивают `performSync` на `InMemoryMeetingRepository.gate(on: .save)`,
    // не на `connector.hang(.fetchEvents)/hangOrGate` — та ворота ОТВЕЧАЮТ на кооперативную
    // отмену (`withTaskCancellationHandler`), а `waitIfGated` НЕТ (простой
    // `withCheckedContinuation`, без обработчика отмены) — задача остаётся застрявшей на
    // `save` СКОЛЬКО УГОДНО, пока тест сам не позовёт `release(on: .save)`. Это и даёт полный
    // контроль над «окном», которое иначе пришлось бы гонять по времени.

    /// Пограничный случай 1: единственный вызывающий, отменённый ДО регистрации
    /// (`Task.isCancelled` уже true на первом синхронном чтении в `awaitSharedSync`) — раньше
    /// такой вызывающий вообще не регистрировался в `syncWaiters` (резолвился `.cancelled`
    /// напрямую) и общая задача никогда не узнавала об уходе своего единственного заказчика.
    /// `task.cancel()` СРАЗУ после создания `Task` — задача ещё не начала выполняться, и
    /// когда она дойдёт до первой проверки `Task.isCancelled`, флаг уже будет взведён (метка
    /// отмены атомарна и не зависит от того, стартовало ли тело задачи).
    ///
    /// Возврат РП (24.09, приёмка #112, бэклог «часть 3г», п. 1): раньше ворота отпускались
    /// только ПОСЛЕ `await task.value` — без фикса (т.е. если `task.cancel()` не долетает до
    /// общей задачи) `await task.value` ждал бы `finishInFlightSync` НАВСЕГДА, поскольку
    /// освободить save-ворота было уже некому — тест сам не дошёл бы до этой строки, а
    /// повис. Без `task.cancel()` (проверено вручную, не в составе теста) единственный
    /// вызывающий получил бы результат ЗАВЕРШИВШЕЙСЯ синхронизации (успех) — сравнение с
    /// `.cancelled` ниже упало бы явной, быстрой ошибкой ассерта, не зависанием CI.
    ///
    /// Возврат РП (24.09, приёмка #115, CI красный на первом прогоне первой версии этого
    /// возврата): `pollUntil { meetingRepositorySaveCallCount(...) >= 1 }` здесь падал
    /// собственным таймаутом (10с) — при РАБОТАЮЩЕМ фиксе отменённая ДО регистрации задача
    /// чаще всего НЕ доходит до `save()` вовсе: `cancelSyncWaiter` отменяет её задачу
    /// (`inFlightSync[source]?.task.cancel()`) почти сразу же, а `ensureInitialized`
    /// (`raceTimeout`) коротится РАНЬШЕ, во время своей собственной гонки с `FakeWaitSeam.
    /// sleep` — та тоже отвечает на уже взведённую `Task.isCancelled` и бросает
    /// `CancellationError`, не дожидаясь ни секунды. «Задача физически не дошла до save-ворот»
    /// — при этом фиксе ЗАКОННЫЙ, ожидаемый исход, не дефект: `pollUntilOrTimeout` (НЕ
    /// проваливает тест сам по себе) ждёт КОРОТКО и БЕЗУСЛОВНО отпускает ворота в конце —
    /// освобождение нужно только как страховка на случай иного порядка (задача всё-таки туда
    /// дошла), а не как условие для прогресса самого теста.
    func test_defect_soleCallerCancelledBeforeRegistrationStillCancelsSharedTask() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: Date())
        ])
        harness.meetingRepository.gate(on: .save)

        let task = Task { await harness.hub.sync(trigger: .manual) }
        task.cancel()

        let taskReachedSaveGate = await pollUntilOrTimeout(timeout: .seconds(1)) {
            meetingRepositorySaveCallCount(harness.meetingRepository) >= 1
        }
        if taskReachedSaveGate {
            harness.meetingRepository.stopGating(on: .save)
            harness.meetingRepository.release(on: .save)
        }

        let results = await task.value
        XCTAssertEqual(results.first?.failure, .cancelled)

        // Без фикса inFlightSync[source] не очистился бы никогда — задача застряла на
        // save-воротах, которые кооперативную отмену не слушают, и pollUntil упал бы явным
        // таймаутом (не тихим зависанием), доказывая именно этот дефект.
        await pollUntil(timeout: .seconds(2)) { await harness.hub.inFlightSync[source] == nil }

        // Безусловная страховка (возврат РП, «в конце отпускай ворота»): если задача всё же
        // дошла до save() уже ПОСЛЕ проверки выше, она не останется висеть навсегда.
        harness.meetingRepository.stopGating(on: .save)
        harness.meetingRepository.release(on: .save)
    }

    /// Пограничный случай 2: после отмены ПОСЛЕДНЕГО ожидающего `inFlightSync[source]`
    /// раньше оставался непустым до фактического завершения задачи — новый вызывающий,
    /// пришедший в это окно, подключился бы к уже обречённой (отменённой) задаче вместо
    /// того, чтобы завести свою.
    ///
    /// CI (24.09, первый прогон этой части): исходная версия теста ждала, что ВТОРОЙ цикл
    /// дойдёт до СВОЕГО `save()`, пока первый (застрявший на воротах) ещё не отпущен —
    /// таймаут за 2 секунды. Причина не в этом фиксе, а в инв. 11 (`mergeTail`,
    /// `CalendarPortImplMerge.swift`): `applyIncoming` ЛЮБОГО цикла сериализован ЕДИНОЙ
    /// цепочкой на весь актор — тело второго `serialized { … }` физически не может начать
    /// работу (включая свой `save()`), пока не завершится ЗАДАЧА первого, что бы ни
    /// случилось с её вызывающим. Это верно и корректно само по себе (та же цепочка не даёт
    /// потерять параллельные слияния), но означает, что при застрявших НЕОТМЕНЯЕМЫХ
    /// save-воротах второй цикл не дойдёт до своего `save()`, пока первый не отпущен —
    /// независимо от того, куда указывает `inFlightSync[source]`. Поэтому здесь проверяется
    /// именно бухгалтерия `syncOne`/`inFlightSync` (то, за что отвечает этот фикс), а
    /// сквозное завершение второго цикла — уже ПОСЛЕ того, как первый отпущен и
    /// merge-цепочка способна продвинуться.
    func test_defect_newCallerAfterLastWaiterCancelsStartsFreshTaskNotTheCancelledOne() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: Date())
        ])
        harness.meetingRepository.gate(on: .save)

        let firstTask = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil { meetingRepositorySaveCallCount(harness.meetingRepository) >= 1 }
        firstTask.cancel()
        let firstResults = await firstTask.value
        XCTAssertEqual(firstResults.first?.failure, .cancelled)

        // Первая (отменённая) задача ВСЁ ЕЩЁ висит на save-воротах — мы её не отпускали.
        // Без фикса inFlightSync[source] остался бы указывать на неё до сих пор.
        await pollUntil(timeout: .seconds(2)) { await harness.hub.inFlightSync[source] == nil }

        // Без фикса второй вызывающий просто подключился бы к syncWaiters уже обречённой
        // (снятой выше) записи и НИКОГДА не завёл бы новую — inFlightSync[source] остался бы
        // nil сколь угодно долго. С фиксом syncOne видит nil и заводит СВОЮ, новую запись
        // немедленно (синхронно внутри актора, без await между проверкой и присваиванием) —
        // до неё merge-цепочка (инв. 11) не участвует вовсе, дожидаться её продвижения не
        // нужно.
        let secondTask = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil(timeout: .seconds(2)) { await harness.hub.inFlightSync[source] != nil }

        // Отпускаем первую (застрявшую) — только теперь общая merge-цепочка (`mergeTail`,
        // инв. 11) способна продвинуться, и вслед за ней — дойти до save второго цикла.
        harness.meetingRepository.stopGating(on: .save)
        harness.meetingRepository.release(on: .save)

        let secondResults = await secondTask.value
        XCTAssertNil(secondResults.first?.failure, "второй вызывающий обязан получить результат СВОЕЙ синхронизации")
        XCTAssertEqual(
            meetingRepositorySaveCallCount(harness.meetingRepository), 2,
            "оба цикла — отпущенный первый и второй — обязаны были дойти до save"
        )
    }

    /// Возврат РП (24.09, приёмка #112, бэклог «часть 3г», п. 2): `finishInFlightSync` уже
    /// защищала бухгалтерию вызывающих генерацией, но сам `setSyncOutcome` внутри
    /// `performSync` такой защиты не имел вовсе — устаревшее (отменённое, уже вытесненное)
    /// поколение, once его СОБСТВЕННАЯ задача всё-таки доходила до конца, писало СВОЙ исход в
    /// `connectorRepository`, как ни в чём не бывало, рискуя переписать уже записанный,
    /// актуальный исход следующего, текущего поколения.
    ///
    /// Возврат РП (24.09, приёмка #115, CI красный на первом прогоне): `recordSyncOutcomeIf
    /// Current`, глуша запись всякий раз, когда `inFlightSync[source]` не совпадает с нашей
    /// генерацией, ломала `test_syncOne_cancellingBothCallersCancelsSharedTask` — там оба
    /// вызывающих отменяются, НИКТО не подхватывает, `inFlightSync[source]` становится `nil`
    /// (не «чужая генерация»), и исход отменённой задачи всё равно обязан быть записан
    /// (защищать не от кого). Guard в проде поправлен: подавляет ТОЛЬКО когда источник уже в
    /// ведении ЧУЖОЙ, отличной от нашей, генерации, не когда он просто пуст. Это же меняет
    /// форму ЭТОГО теста: чтобы устаревшая запись подавлялась, новое поколение обязано быть
    /// УЖЕ ЗАРЕГИСТРИРОВАНО (`inFlightSync[source]` уже указывает на него) к моменту, когда
    /// устаревшее доходит до своей попытки записи — поэтому второе поколение заводится ДО
    /// того, как первое отпускается, не после.
    ///
    /// Проверка — ЧИСТЫЙ СЧЁТЧИК вызовов `setSyncOutcome`, а не итоговое значение в
    /// хранилище: без фикса счётчик стал бы 2 независимо от того, какая из двух попыток в
    /// итоге осталась видна в `storedRecords`.
    func test_defect_staleGenerationDoesNotWriteSyncOutcome() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: Date())
        ])
        harness.meetingRepository.gate(on: .save)

        let firstTask = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil { meetingRepositorySaveCallCount(harness.meetingRepository) >= 1 }
        let firstGeneration = await harness.hub.inFlightSync[source]
        let firstGenerationTask = firstGeneration?.task
        XCTAssertNotNil(firstGenerationTask, "первое поколение обязано существовать на этот момент")
        firstTask.cancel()
        let firstResults = await firstTask.value
        XCTAssertEqual(firstResults.first?.failure, .cancelled)
        await pollUntil(timeout: .seconds(2)) { await harness.hub.inFlightSync[source] == nil }

        // Новое поколение заводим СЕЙЧАС, пока устаревшее ещё физически не отпущено — к
        // моменту его записи inFlightSync обязан уже указывать на новое, не на nil.
        let secondTask = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil(timeout: .seconds(2)) { await harness.hub.inFlightSync[source] != nil }

        // Устаревшее поколение всё ещё физически висит на save-воротах — отпускаем его с
        // заранее взведённым отказом, чтобы у его (потенциальной) записи был заведомо
        // отличимый от честного успеха вид, и ждём его СОБСТВЕННУЮ задачу до конца (не
        // firstTask — тот уже вернул .cancelled вызывающему безотносительно судьбы самой
        // задачи).
        harness.meetingRepository.fail(
            with: .dataCorrupted(entity: "meeting", id: "n/a", message: "устаревшее поколение"), on: .save
        )
        harness.meetingRepository.release(on: .save)
        _ = await firstGenerationTask?.value
        harness.meetingRepository.stopGating(on: .save)
        harness.meetingRepository.clearFailure(on: .save)

        let secondResults = await secondTask.value
        XCTAssertNil(secondResults.first?.failure, "новое поколение обязано завершиться успешно")

        XCTAssertEqual(
            connectorRepositorySetSyncOutcomeCallCount(harness.connectorRepository), 1,
            "устаревшее поколение не должно писать свой исход вовсе"
        )
        XCTAssertNil(
            harness.connectorRepository.storedRecords.first?.lastError,
            "итоговое состояние обязано отражать честный успех текущего поколения"
        )
    }
}
