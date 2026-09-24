//  CalendarPortImpl+Sync — синхронизация источников (К30-К39, К42-К43, К71-К72), дедуп по
//  признакам (а)/(б) правила слияния C-005 п.4 (реализует К17-К19, К29, К31 — возврат РП,
//  приёмка #85, дефект 6: заявление «покрыты» здесь раньше значило «есть тесты», тестов не
//  было ни строки; тестов на К17-К19/К29/К31 по-прежнему нет — задача остаётся открытой,
//  файл под неё не заведён — возврат РП, приёмка #94, п. 2).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен
//
//  Вынесено из CalendarPortImpl.swift отдельным файлом — тот же приём, что у `capture`
//  (`AudioCaptureImpl+Rebuild.swift` и соседи): SwiftLint `file_length`/`type_body_length`
//  считают КАЖДОЕ расширение типа отдельно, а не суммой по всем файлам модуля — актор
//  остаётся одним типом, просто с несколькими лексическими областями.

import Foundation
import DomainCore

extension CalendarPortImpl {

    public func sync(trigger: CalendarSyncTrigger) async -> [CalendarSyncResult] {
        let sources = await listSources()
        return await withTaskGroup(of: CalendarSyncResult.self) { group in
            // Развилка Р7: параллельно, один Task на источник — syncOne(source:trigger:).
            for source in sources {
                group.addTask { await self.syncOne(source: source, trigger: trigger) }
            }
            var results: [CalendarSyncResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    // НАЙДЕНО (бисекция CI-зависания, MEE-362 ч.2 — К67, не среди семи дефектов приёмки
    // #85, обнаружено ЭТИМ новым тестом): `Task { await self.performSync(...) }` —
    // неструктурная задача; `await task.value` сама по себе НЕ передаёт отмену вызывающего
    // контекста внутрь неё (отмена структурно каскадится только в дочерние задачи
    // `TaskGroup`/`async let`, не в свободный `Task { }`). Отмена `sync()`'s группы
    // (К67 — `task.cancel()` в тесте) доходила до самого `syncOne`, но НЕ доходила до
    // `performSync`'а внутри — задержка повтора §5.2 (`waitSeam.sleep`, свои корректные
    // ворота ждут явной отмены СВОЕЙ задачи) не получала отмену никогда и висела до конца
    // процесса `swift test`.
    //
    // СТРОКА (возврат РП, приёмка #94, п. 1 — первый заход `withTaskCancellationHandler {
    // await task.value } onCancel: { task.cancel() }` был неверен другим способом): К35
    // («второй параллельный вызов получает результат уже идущего, не запускает второй»)
    // значит НЕСКОЛЬКО вызывающих делят ОДНУ `task` — `task.cancel()` в `onCancel` одного
    // вызывающего отменял бы общую задачу и для остальных, ничего не просивших об отмене.
    // Фикс — предохранитель НА ВЫЗЫВАЮЩЕГО, не на саму задачу: каждый вызов регистрирует
    // свой continuation в `syncWaiters[source]` (тот же приём с `UUID`-ключом и гонкой
    // «уже отменена до регистрации», что `hangOrGate`/`FakeWaitSeam.sleep`); настоящая
    // `task` фоновым `Task` (`finishInFlightSync`) при завершении рассылает результат ВСЕМ
    // зарегистрированным ожидающим разом. Отмена одного вызывающего снимает ТОЛЬКО его
    // запись и отдаёт ему `.cancelled` — саму `task` это не трогает, пока у неё остаётся
    // хоть один незавершённый ожидающий; когда последний тоже уходит (отменой или обычным
    // получением результата), `task.cancel()` вызывается ровно один раз — тот же довод К67
    // (отмена единственного вызывающего обязана по-настоящему прервать §5.2), просто не
    // ценой чужих вызовов.
    /// Внутренняя, непубличная операция развилки Р6 — обходит ОДИН источник, не все
    /// (публичный `sync(trigger:)` параметра источника не несёт). Вызывается и публичным
    /// `sync`, и push-обработчиком (`notify(.changesAvailable)`, К61) напрямую.
    /// Не-реентерантна на источник (К35) — второй параллельный вызов для того же
    /// источника получает результат уже идущего, не запускает второй.
    func syncOne(source: CalendarSourceId, trigger: CalendarSyncTrigger) async -> CalendarSyncResult {
        if inFlightSync[source] == nil {
            let generation = UUID()
            let task = Task { await self.performSync(source: source, trigger: trigger, generation: generation) }
            inFlightSync[source] = (generation, task)
            Task { await self.finishInFlightSync(source: source, generation: generation, task: task) }
        }
        return await awaitSharedSync(source: source, trigger: trigger)
    }

    /// Возврат РП (приёмка #94, бэклог MEE-386, п. 2/двух пограничных случаев): `generation`
    /// (заведён в `syncOne`, хранится рядом с `task` в `inFlightSync`) — без него, если ПОСЛЕ
    /// отмены последнего ожидающего (`cancelSyncWaiter` ниже обнуляет `inFlightSync[source]`
    /// сразу, не дожидаясь фактического завершения задачи) успевал прийти новый вызывающий,
    /// он стартовал бы СВОЮ задачу под тем же ключом источника — а когда СТАРАЯ (уже
    /// отменённая) задача потом всё-таки заканчивалась, этот же метод, зная только `source`,
    /// не смог бы отличить «это ещё моя генерация» от «источник уже занят чужой, более новой»
    /// и либо обнулил бы чужую свежую запись `inFlightSync`, либо (хуже) разослал бы
    /// результат ОТМЕНЁННОЙ задачи новым ожидающим, которые ничего не отменяли. Guard ниже —
    /// единственная защита: не наша генерация — свежие `syncWaiters` принадлежат чужой
    /// задаче, их трогать нечем (по построению `cancelSyncWaiter` уже разослала ВСЕХ
    /// ожидающих ПРЕЖНЕЙ генерации `.cancelled`, прежде чем обнулить `inFlightSync` —
    /// оставленных «хвостов» той генерации в `syncWaiters` быть не может).
    private func finishInFlightSync(
        source: CalendarSourceId, generation: UUID, task: Task<CalendarSyncResult, Never>
    ) async {
        let result = await task.value
        guard inFlightSync[source]?.generation == generation else { return }
        inFlightSync[source] = nil
        let waiters = syncWaiters.removeValue(forKey: source) ?? [:]
        for continuation in waiters.values {
            continuation.resume(returning: result)
        }
    }

    /// Возврат РП (приёмка #94, бэклог MEE-386, п. 1/двух пограничных случаев): раньше
    /// вызывающий, отменённый ЕЩЁ ДО входа сюда (`Task.isCancelled` уже true на первом же
    /// синхронном чтении), вообще не регистрировался в `syncWaiters` — резолвился `.cancelled`
    /// напрямую, минуя `cancelSyncWaiter`. Если он был ЕДИНСТВЕННЫМ ожидающим источника,
    /// общая задача никогда не узнавала, что ушёл её последний (и единственный) заказчик, и
    /// доживала до конца сама по себе, включая задержку повтора §5.2 — впустую, работать
    /// было уже не для кого. Регистрация теперь БЕЗУСЛОВНАЯ (до проверки отмены), а отмена —
    /// через ТОТ ЖЕ `cancelSyncWaiter`, что и обычный путь: он идемпотентен (see: guard на
    /// `removeValue`), так что двойной вызов (отсюда и из `onCancel` ниже, если гонка) ничего
    /// не портит — второй просто находит запись уже снятой и не делает ничего.
    private func awaitSharedSync(source: CalendarSourceId, trigger: CalendarSyncTrigger) async -> CalendarSyncResult {
        let key = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CalendarSyncResult, Never>) in
                syncWaiters[source, default: [:]][key] = continuation
                if Task.isCancelled {
                    cancelSyncWaiter(source: source, key: key, trigger: trigger)
                }
            }
        } onCancel: {
            Task { await self.cancelSyncWaiter(source: source, key: key, trigger: trigger) }
        }
    }

    /// Снимает СВОЮ запись и только свою; если после этого у источника не осталось ни
    /// одного ожидающего, а настоящая задача ещё не завершилась — она больше никому не
    /// нужна, отменяем её здесь (ровно один раз, тем же вызовом, что снял последнего).
    /// Обнуление `inFlightSync[source]` В ЭТОТ ЖЕ МОМЕНТ (не дожидаясь фактического
    /// завершения задачи в `finishInFlightSync`) — часть фикса п. 2: следующий вызывающий,
    /// заставший источник уже без ожидающих, обязан завести СВОЮ, новую задачу, а не
    /// присоединиться к уже обречённой отменённой — `finishInFlightSync` эту старую задачу
    /// потом всё равно корректно доведёт до конца по `generation`, просто никому этот
    /// результат уже не разошлёт (см. его докстринг).
    private func cancelSyncWaiter(source: CalendarSourceId, key: UUID, trigger: CalendarSyncTrigger) {
        guard let continuation = syncWaiters[source]?.removeValue(forKey: key) else { return }
        continuation.resume(returning: Self.cancelledResult(source: source, trigger: trigger))
        if syncWaiters[source]?.isEmpty ?? true {
            syncWaiters[source] = nil
            inFlightSync[source]?.task.cancel()
            inFlightSync[source] = nil
        }
    }

    private static func cancelledResult(source: CalendarSourceId, trigger: CalendarSyncTrigger) -> CalendarSyncResult {
        let now = Date()
        return CalendarSyncResult(
            sourceId: source, trigger: trigger, startedAt: now, finishedAt: now,
            upsertedCount: 0, deletedCount: 0, failure: .cancelled
        )
    }

    private func performSync(
        source: CalendarSourceId, trigger: CalendarSyncTrigger, generation: UUID
    ) async -> CalendarSyncResult {
        let startedAt = Date()
        do {
            guard let connector = connectors[source] else {
                throw CalendarError.notConfigured(sourceId: source)
            }
            try await ensureInitialized(source, connector: connector)
            let record = try await requireRecord(source)
            let outcome = try await fetchAndApply(source: source, connector: connector, record: record)
            await recordSyncOutcomeIfCurrent(source: source, generation: generation, error: nil)
            return CalendarSyncResult(
                sourceId: source, trigger: trigger, startedAt: startedAt, finishedAt: Date(),
                upsertedCount: outcome.upserted, deletedCount: outcome.deleted, failure: nil
            )
        } catch let error as CalendarError {
            // Развилка Р3: отказ не меняет сохранённое состояние источника ни в одной строке.
            await recordSyncOutcomeIfCurrent(
                source: source, generation: generation, error: String(describing: error)
            )
            return CalendarSyncResult(
                sourceId: source, trigger: trigger, startedAt: startedAt, finishedAt: Date(),
                upsertedCount: 0, deletedCount: 0, failure: error
            )
        } catch {
            // Возврат РП (приёмка #85, дефект 4): эта ветка не писала через setSyncOutcome
            // вовсе, в отличие от ветки CalendarError выше — ConnectorRecord.lastError не
            // обновлялся на ошибках, не являющихся CalendarError (например, StorageError
            // из репозиториев). Тот же вызов, что и там.
            let mapped = CalendarError.transport(sourceId: source, message: String(describing: error))
            await recordSyncOutcomeIfCurrent(
                source: source, generation: generation, error: String(describing: mapped)
            )
            return CalendarSyncResult(
                sourceId: source, trigger: trigger, startedAt: startedAt, finishedAt: Date(),
                upsertedCount: 0, deletedCount: 0, failure: mapped
            )
        }
    }

    /// Возврат РП (24.09, приёмка #112, бэклог «часть 3г», п. 2): `finishInFlightSync`
    /// защищает бухгалтерию вызывающих (`inFlightSync`/`syncWaiters`) проверкой `generation`,
    /// но САМ `setSyncOutcome` внутри `performSync` этой проверки не имел вовсе — устаревшее
    /// (отменённое, замещённое новым вызывающим) поколение, once отпущено воротами теста или
    /// коннектор перестал висеть, всё равно доходило до конца и писало СВОЙ исход
    /// (`transport(CancellationError)`, если что-то по пути бросило отмену, либо честный
    /// успех/отказ) в `connectorRepository` — независимо от того, что к этому моменту источник
    /// уже мог обслуживать СЛЕДУЮЩЕЕ, более новое поколение с собственным, уже записанным
    /// исходом. Гонка по времени: если устаревшая запись физически проигрывает свежей (её
    /// `await` в глубине `fetchAndApply` просто медленнее), она перетирает корректный исход
    /// новой синхронизации неверным. Guard здесь — тот же приём, что `finishInFlightSync`: не
    /// наша генерация (источник уже не в её ведении, `inFlightSync[source]` либо `nil`, либо
    /// указывает на чужую) — писать нечего, наш исход больше никого не касается.
    private func recordSyncOutcomeIfCurrent(source: CalendarSourceId, generation: UUID, error: String?) async {
        guard inFlightSync[source]?.generation == generation else { return }
        try? await connectorRepository.setSyncOutcome(at: Date(), error: error, connectorId: source.rawValue)
    }

    private struct SyncOutcome { var upserted = 0; var deleted = 0 }

    /// К2/К43/К71 — выбор fetchEvents/fetchChanges; К72 — calendarIds == selectedCalendarIds.
    private func fetchAndApply(
        source: CalendarSourceId, connector: CalendarConnector, record: ConnectorRecord
    ) async throws -> SyncOutcome {
        let caps = capabilities[source]
        let calendarIds = record.selectedCalendarIds
        if caps?.deltaSync == true, let cursor = record.cursor {
            return try await applyDeltaSync(
                source: source, connector: connector, cursor: cursor, calendarIds: calendarIds
            )
        }
        if caps?.deltaSync == true, record.cursor == nil {
            // Развилка Р9: первая синхронизация — сначала fetchChanges(nil), затем
            // fetchEvents на полном окне Р2, в этом порядке, тем же циклом.
            //
            // Возврат РП (приёмка #85, дефект 1): `applyFirstDeltaStep` НЕ сохраняет курсор
            // сама — если бы курсор шага 1 сохранялся сразу (как делает обычный
            // `applyDeltaSync` для уже идущей дельта-синхронизации), а шаг 2 (полное окно)
            // упал, следующий цикл увидел бы курсор уже сохранённым и пошёл бы по дельте —
            // полное окно не загрузилось бы никогда. Курсор пишется здесь, ПОСЛЕ того как
            // applyFullWindow тоже завершилась успешно (если бы она бросила, до этой строки
            // выполнение не дошло бы вовсе).
            let (deltaOutcome, pendingCursor) = try await applyFirstDeltaStep(
                source: source, connector: connector, calendarIds: calendarIds
            )
            let full = try await applyFullWindow(source: source, connector: connector, calendarIds: calendarIds)
            if let pendingCursor {
                try await connectorRepository.setCursor(pendingCursor, connectorId: source.rawValue)
            }
            var outcome = deltaOutcome
            outcome.upserted += full.upserted
            outcome.deleted += full.deleted
            return outcome
        }
        return try await applyFullWindow(source: source, connector: connector, calendarIds: calendarIds)
    }

    /// Развилка Р2: окно всегда `[now-7д, now+90д)` от текущего `now`, не зависит от
    /// `lastSyncAt` и не растёт со временем жизни установки.
    private func applyFullWindow(
        source: CalendarSourceId, connector: CalendarConnector, calendarIds: [String]
    ) async throws -> SyncOutcome {
        let now = Date()
        let from = now.addingTimeInterval(-7 * 24 * 3600)
        let to = now.addingTimeInterval(90 * 24 * 3600)
        let payloads = try await callConnector(source: source, connector: connector, timeout: .fetchWindow) {
            try await connector.fetchEvents(from: from, to: to, calendarIds: calendarIds)
        }
        var outcome = SyncOutcome()
        for payload in payloads where try await applyIncoming(payload: payload) {
            outcome.upserted += 1
        }
        return outcome
    }

    private func applyDeltaSync(
        source: CalendarSourceId, connector: CalendarConnector, cursor: String?, calendarIds: [String]
    ) async throws -> SyncOutcome {
        do {
            let batch = try await callConnector(source: source, connector: connector, timeout: .fetchWindow) {
                try await connector.fetchChanges(cursor: cursor, calendarIds: calendarIds)
            }
            var outcome = SyncOutcome()
            for payload in batch.events where try await applyIncoming(payload: payload) {
                outcome.upserted += 1
            }
            for externalId in batch.deletedExternalIds
            where try await applyDeletedExternalId(source: source, externalId: externalId) {
                outcome.deleted += 1
            }
            // К64 вход А: события/удаления пакета — ДО сохранения курсора того же пакета.
            try await connectorRepository.setCursor(batch.cursor, connectorId: source.rawValue)
            if batch.resetRequired {
                // Инв. 8: следующая синхронизация — fetchEvents, не fetchChanges.
                // `fetchAndApply` выбирает `applyDeltaSync` только когда `record.cursor !=
                // nil` (развилка Р9) — nil-курсор здесь не «курсор не годен», а единственный
                // рычаг, которым этот модуль просит у самого себя fetchEvents следующим
                // циклом; отдельного флага под это не заводим (К43 не запрещает курсору
                // существовать, требует только самого факта следующего fetchEvents).
                try await connectorRepository.setCursor(nil, connectorId: source.rawValue)
            }
            return outcome
        } catch let error as ConnectorError {
            guard case .cursorInvalid = error else { throw Self.mapConnectorError(error, source: source) }
            // Инв. 19: протухший курсор — забыть, fetchEvents на полном окне, результат
            // источника = результат этого вызова, -32004 наружу не идёт никогда.
            try await connectorRepository.setCursor(nil, connectorId: source.rawValue)
            do {
                return try await applyFullWindow(source: source, connector: connector, calendarIds: calendarIds)
            } catch let inner as ConnectorError {
                guard case .cursorInvalid = inner else { throw Self.mapConnectorError(inner, source: source) }
                // Повторный -32004/cursorInvalid на шаге 2 — НЕ третий забытый повтор,
                // сама эта ошибка выходит наружу (в отличие от первого -32004).
                throw CalendarError.protocolViolation(
                    sourceId: source, message: "cursorInvalid повторно на полном окне после сброса курсора"
                )
            }
        }
    }

    /// Развилка Р9, шаг 1: `fetchChanges(cursor: nil)`, применяет пакет, НЕ сохраняет курсор
    /// — вызывающая сторона (`fetchAndApply`) сохраняет его сама, только после того как
    /// шаг 2 (`applyFullWindow`) тоже прошёл успешно (возврат РП, дефект 1). Разделена с
    /// обычным `applyDeltaSync` намеренно, не общим параметром "persist" на нём: тот метод
    /// вызывает СВОЙ собственный резервный `applyFullWindow` изнутри catch-ветки
    /// `cursorInvalid` — двух независимых источников «применить полное окно» в одном цикле
    /// быть не должно, а общий флаг это бы запутал.
    private func applyFirstDeltaStep(
        source: CalendarSourceId, connector: CalendarConnector, calendarIds: [String]
    ) async throws -> (outcome: SyncOutcome, pendingCursor: String?) {
        do {
            let batch = try await callConnector(source: source, connector: connector, timeout: .fetchWindow) {
                try await connector.fetchChanges(cursor: nil, calendarIds: calendarIds)
            }
            var outcome = SyncOutcome()
            for payload in batch.events where try await applyIncoming(payload: payload) {
                outcome.upserted += 1
            }
            for externalId in batch.deletedExternalIds
            where try await applyDeletedExternalId(source: source, externalId: externalId) {
                outcome.deleted += 1
            }
            if batch.resetRequired {
                // Инв. 8: курсор всё равно должен стать nil — можно сразу, дефект 1 защищает
                // только НЕПУСТОЙ курсор, потерять здесь нечего.
                try await connectorRepository.setCursor(nil, connectorId: source.rawValue)
                return (outcome, nil)
            }
            return (outcome, batch.cursor)
        } catch let error as ConnectorError {
            guard case .cursorInvalid = error else { throw Self.mapConnectorError(error, source: source) }
            // Курсор на этом шаге уже nil — «протухшего» курсора в обычном смысле инв. 19
            // здесь нет; трактуем как «пакета нет», без собственного резервного полного окна
            // (его и так сейчас вызовет fetchAndApply — вызывающая сторона).
            return (SyncOutcome(), nil)
        }
    }
}
