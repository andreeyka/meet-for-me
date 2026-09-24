//  CalendarPortImpl+Sync — синхронизация источников (К30-К39, К42-К43, К71-К72), дедуп по
//  признакам (а)/(б) правила слияния C-005 п.4 (К17-К19, К29, К31).
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
    func syncOne(source: CalendarSourceId, trigger: CalendarSyncTrigger) async -> CalendarSyncResult {
        if let running = inFlightSync[source] {
            return await running.value
        }
        let task = Task { await self.performSync(source: source, trigger: trigger) }
        inFlightSync[source] = task
        let result = await task.value
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
            let mapped = CalendarError.transport(sourceId: source, message: String(describing: error))
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
            var outcome = try await applyDeltaSync(
                source: source, connector: connector, cursor: nil, calendarIds: calendarIds
            )
            let full = try await applyFullWindow(source: source, connector: connector, calendarIds: calendarIds)
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

    /// Назначение id по правилу слияния C-005 п.4 (признаки а/б — К17-К19, К29). Слияние
    /// скаляров/`attendees` по п.2-3 и ассоциативность/коммутативность (К20-К24, К28) —
    /// ОТДЕЛЬНАЯ, ещё не написанная в этой правке работа: здесь пока «последний пишет
    /// поверх» на уровне СКАЛЯРОВ целиком, не честный fallback по возрастанию
    /// `sourceConnectorId` для отдельных полей. К17-К19, К29, К31 — покрыты. К20-К24, К28 —
    /// НЕ покрыты этой правкой, следующая часть.
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
        // К65 вход Б: источник теряется у многоисточниковой встречи — не `.deleted`.
        // Пересчёт содержимого по оставшимся источникам (правило слияния п.1-2) — та же
        // ещё не написанная работа, что К20-К24: здесь только источник убирается из
        // списка, содержимое `event` не пересчитывается заново. К65 вход Б покрыт этой
        // правкой лишь частично — «не .deleted» да, «пересчёт по оставшимся» нет ещё.
        let remaining = record.sources.filter {
            !($0.sourceConnectorId == source.rawValue && $0.externalId == externalId)
        }
        try await meetingRepository.save(
            MeetingRecord(event: record.event, dedupKey: record.dedupKey, status: record.status, sources: remaining)
        )
        return false
    }
}
