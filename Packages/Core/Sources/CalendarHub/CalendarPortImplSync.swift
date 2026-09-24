//  CalendarPortImpl+Sync — синхронизация источников (К30-К39, К42-К43, К71-К72), дедуп по
//  признакам (а)/(б) правила слияния C-005 п.4 (реализует К17-К19, К29, К31 — возврат РП,
//  приёмка #85, дефект 6: заявление «покрыты» здесь раньше значило «есть тесты», тестов не
//  было ни строки; актуальное покрытие тестами называет шапка `DedupAndMergeTests.swift`).
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

    /// Внутренняя, непубличная операция развилки Р6 — обходит ОДИН источник, не все
    /// (публичный `sync(trigger:)` параметра источника не несёт). Вызывается и публичным
    /// `sync`, и push-обработчиком (`notify(.changesAvailable)`, К61) напрямую.
    /// Не-реентерантна на источник (К35) — второй параллельный вызов для того же
    /// источника получает результат уже идущего, не запускает второй.
    // НАЙДЕНО (бисекция CI-зависания, MEE-362 ч.2 — К67, не среди семи дефектов приёмки
    // #85, обнаружено ЭТИМ новым тестом): `Task { await self.performSync(...) }` —
    // неструктурная задача; `await task.value`/`await running.value` сами по себе НЕ
    // передают отмену вызывающего контекста внутрь неё (отмена структурно каскадится
    // только в дочерние задачи `TaskGroup`/`async let`, не в свободный `Task { }`).
    // Отмена `sync()`'s группы (К67 — `task.cancel()` в тесте) доходила до самого
    // `syncOne`, но НЕ доходила до `performSync`'а внутри — задержка повтора §5.2
    // (`waitSeam.sleep`, свои корректные ворота ждут явной отмены СВОЕЙ задачи) не
    // получала отмену никогда и висела до конца процесса `swift test`.
    // `withTaskCancellationHandler` пробрасывает `.cancel()` явно на саму `task`/
    // `running` — тем же приёмом, что `hangOrGate`/`FakeWaitSeam.sleep` уже используют
    // сами по себе, только на один уровень выше.
    func syncOne(source: CalendarSourceId, trigger: CalendarSyncTrigger) async -> CalendarSyncResult {
        if let running = inFlightSync[source] {
            return await withTaskCancellationHandler {
                await running.value
            } onCancel: {
                running.cancel()
            }
        }
        let task = Task { await self.performSync(source: source, trigger: trigger) }
        inFlightSync[source] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlightSync[source] = nil
        return result
    }

    private func performSync(source: CalendarSourceId, trigger: CalendarSyncTrigger) async -> CalendarSyncResult {
        let startedAt = Date()
        do {
            guard let connector = connectors[source] else {
                throw CalendarError.notConfigured(sourceId: source)
            }
            try await ensureInitialized(source, connector: connector)
            let record = try await requireRecord(source)
            let outcome = try await fetchAndApply(source: source, connector: connector, record: record)
            try? await connectorRepository.setSyncOutcome(at: Date(), error: nil, connectorId: source.rawValue)
            return CalendarSyncResult(
                sourceId: source, trigger: trigger, startedAt: startedAt, finishedAt: Date(),
                upsertedCount: outcome.upserted, deletedCount: outcome.deleted, failure: nil
            )
        } catch let error as CalendarError {
            // Развилка Р3: отказ не меняет сохранённое состояние источника ни в одной строке.
            try? await connectorRepository.setSyncOutcome(
                at: Date(), error: String(describing: error), connectorId: source.rawValue
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
            try? await connectorRepository.setSyncOutcome(
                at: Date(), error: String(describing: mapped), connectorId: source.rawValue
            )
            return CalendarSyncResult(
                sourceId: source, trigger: trigger, startedAt: startedAt, finishedAt: Date(),
                upsertedCount: 0, deletedCount: 0, failure: mapped
            )
        }
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

    /// Назначение id по правилу слияния C-005 п.4 (признаки а/б — реализует К17-К19, К29).
    /// Слияние скаляров/`attendees` по п.2-3 в честном виде (fallback по возрастанию
    /// `sourceConnectorId` для каждого отдельного поля, К20-К24, К28) НЕ реализовано —
    /// `MeetingSource` не хранит per-source сырые поля (IR-126/MEE-372, не решено
    /// архитектором); здесь пока «последний пишет поверх» на уровне СКАЛЯРОВ целиком. К20-К24
    /// тестами покрыты только В ПРЕДЕЛАХ одной синхронизации (`DedupAndMergeTests.swift`,
    /// см. его шапку) — межсинхронизационное честное слияние ждёт того же IR-126.
    @discardableResult
    private func applyIncoming(payload: MeetingEventPayload) async throws -> Bool {
        let provisional = try payload.assigningId(UUID())
        let key = DedupKey.make(from: provisional)
        var winner: MeetingRecord?
        if let key {
            winner = try await meetingRepository.meeting(dedupKey: key)
        }
        if winner == nil {
            winner = try await meetingRepository.meeting(
                sourceConnectorId: payload.sourceConnectorId, externalId: payload.externalId
            )
        }
        let id = winner?.event.id ?? UUID()
        let resolvedEvent = try payload.assigningId(id)
        let newSource = MeetingSource(
            sourceConnectorId: payload.sourceConnectorId, externalId: payload.externalId,
            icalUid: payload.icalUid, lastModified: payload.lastModified
        )
        var sources = winner?.sources.filter {
            !($0.sourceConnectorId == newSource.sourceConnectorId && $0.externalId == newSource.externalId)
        } ?? []
        sources.append(newSource)
        try await meetingRepository.save(
            MeetingRecord(
                event: resolvedEvent, dedupKey: DedupKey.make(from: resolvedEvent),
                status: winner?.status ?? .ready, sources: sources
            )
        )
        emit(.upserted([resolvedEvent]))
        return true
    }

    private func applyDeletedExternalId(source: CalendarSourceId, externalId: String) async throws -> Bool {
        guard let record = try await meetingRepository.meeting(
            sourceConnectorId: source.rawValue, externalId: externalId
        ) else { return false }
        if record.sources.count <= 1 {
            try await meetingRepository.delete(meetingIds: [record.event.id])
            emit(.deleted([record.event.id]))
            return true
        }
        // СТРОКА (возврат РП, приёмка #85, дефект 5 — проверено против C-005 п.4 по его
        // прямому требованию): К65 вход Б — источник теряется у многоисточниковой встречи,
        // «не .deleted» соблюдено. Контракт НЕ говорит явно, обязан ли `event` при этом
        // пересчитываться по оставшимся источникам заново, если проигравший (уже удалённый)
        // источник был победителем правила слияния п.2-3 — молчание того же рода, что
        // К20-К24/К28 (MeetingSource без сырых полей источника, IR-126/MEE-372): честное
        // слияние скаляров по правилу «победитель — источник» здесь так же неисполнимо без
        // той же схемы. Вилка не решена мной:
        // (а) как сейчас — `event` не пересчитывается, источник просто убирается из списка;
        //     до IR-126 остаётся тем же временным «последний пишет поверх», что у К20-К24;
        // (б) `event` обязан пересчитываться по оставшимся источникам сразу, тем же
        //     проходом `applyIncoming` использовал бы для НОВОГО входящего payload — требует
        //     ту же схему (per-source сырые поля), которой сегодня нет.
        // Не меняю поведение до решения IR-126 (инструкция РП, приёмка #85) — находка та же,
        // не вторая.
        let remaining = record.sources.filter {
            !($0.sourceConnectorId == source.rawValue && $0.externalId == externalId)
        }
        try await meetingRepository.save(
            MeetingRecord(event: record.event, dedupKey: record.dedupKey, status: record.status, sources: remaining)
        )
        return false
    }
}
