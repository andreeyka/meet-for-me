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
            let task = Task { await self.performSync(source: source, trigger: trigger) }
            inFlightSync[source] = task
            Task { await self.finishInFlightSync(source: source, task: task) }
        }
        return await awaitSharedSync(source: source, trigger: trigger)
    }

    private func finishInFlightSync(source: CalendarSourceId, task: Task<CalendarSyncResult, Never>) async {
        let result = await task.value
        inFlightSync[source] = nil
        let waiters = syncWaiters.removeValue(forKey: source) ?? [:]
        for continuation in waiters.values {
            continuation.resume(returning: result)
        }
    }

    private func awaitSharedSync(source: CalendarSourceId, trigger: CalendarSyncTrigger) async -> CalendarSyncResult {
        let key = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CalendarSyncResult, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: Self.cancelledResult(source: source, trigger: trigger))
                    return
                }
                syncWaiters[source, default: [:]][key] = continuation
            }
        } onCancel: {
            Task { await self.cancelSyncWaiter(source: source, key: key, trigger: trigger) }
        }
    }

    /// Снимает СВОЮ запись и только свою; если после этого у источника не осталось ни
    /// одного ожидающего, а настоящая задача ещё не завершилась — она больше никому не
    /// нужна, отменяем её здесь (ровно один раз, тем же вызовом, что снял последнего).
    private func cancelSyncWaiter(source: CalendarSourceId, key: UUID, trigger: CalendarSyncTrigger) {
        guard let continuation = syncWaiters[source]?.removeValue(forKey: key) else { return }
        continuation.resume(returning: Self.cancelledResult(source: source, trigger: trigger))
        if syncWaiters[source]?.isEmpty ?? true {
            syncWaiters[source] = nil
            inFlightSync[source]?.cancel()
        }
    }

    private static func cancelledResult(source: CalendarSourceId, trigger: CalendarSyncTrigger) -> CalendarSyncResult {
        let now = Date()
        return CalendarSyncResult(
            sourceId: source, trigger: trigger, startedAt: now, finishedAt: now,
            upsertedCount: 0, deletedCount: 0, failure: .cancelled
        )
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

    /// Инв. 11 (C-005, MEE-385): слияние ДВУХ входящих событий ОДНОЙ встречи (тот же дедуп-
    /// ключ) сериализуется — очередь задач на ключ (`mergeTail`), атомарно или строгим
    /// порядком, так что конкурентное чтение-запись двух таких событий не теряет ни одно.
    /// Разные встречи сливаются независимо и параллельно, как и раньше — нет записи в
    /// словаре под их ключом, нет и ожидания. `TaskGroup` (`sync(trigger:)`, один `Task` на
    /// источник) плюс реентерабельность актора на `await` иначе могут перекрыть запись
    /// одного входящего события записью другого, ещё не слитого с ним.
    private func serialized<T: Sendable>(
        dedupKey: DedupKey?, _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        guard let dedupKey else { return try await body() }
        let previous = mergeTail[dedupKey]
        // Task<T, Error> (обычный, «сырой» throws), не Task<Result<T, Error>, Never>: голый
        // `Error` не Sendable, Result<T, Error> с ним тоже не Sendable — Task этого от
        // Success (T) требует, но не от Failure (`Task<Success, Failure> where Success:
        // Sendable, Failure: Error` — без Sendable у Failure), так что throws-задача сама по
        // себе, без ручной упаковки в Result, — верный и более простой путь.
        let task = Task<T, Error> {
            _ = await previous?.value
            return try await body()
        }
        mergeTail[dedupKey] = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Назначение id по правилу слияния C-005 п.4 (признаки а/б). Слияние скаляров/
    /// `attendees` по шагам 2-3 — теперь честное, не «последний пишет поверх»:
    /// `MeetingSource.payload` (IR-126, C-010 v18 инв. 31, MEE-384) хранит снимок каждого
    /// источника, перенесённый между циклами дословно (инв. 10 C-005) — свежий `payload`
    /// заменяет снимок ТОЛЬКО своей пары (`sourceConnectorId`/`externalId`), остальные
    /// переносятся как есть из уже сохранённого состояния, не пересобираются заново со
    /// значением по умолчанию `nil`.
    @discardableResult
    private func applyIncoming(payload: MeetingEventPayload) async throws -> Bool {
        let provisional = try payload.assigningId(UUID())
        let key = DedupKey.make(from: provisional)
        return try await serialized(dedupKey: key) {
            try await self.mergeIncoming(payload: payload, dedupKey: key)
        }
    }

    private func mergeIncoming(payload: MeetingEventPayload, dedupKey: DedupKey?) async throws -> Bool {
        var winner: MeetingRecord?
        if let dedupKey {
            winner = try await meetingRepository.meeting(dedupKey: dedupKey)
        }
        if winner == nil {
            winner = try await meetingRepository.meeting(
                sourceConnectorId: payload.sourceConnectorId, externalId: payload.externalId
            )
        }

        let newSource = MeetingSource(
            sourceConnectorId: payload.sourceConnectorId, externalId: payload.externalId,
            icalUid: payload.icalUid, lastModified: payload.lastModified, payload: payload
        )
        var sources = winner?.sources.filter {
            !($0.sourceConnectorId == newSource.sourceConnectorId && $0.externalId == newSource.externalId)
        } ?? []
        sources.append(newSource)

        let id = winner?.event.id ?? UUID()
        let merged = try Self.merge(sources: sources, id: id)
        try await meetingRepository.save(
            MeetingRecord(
                event: merged, dedupKey: DedupKey.make(from: merged),
                status: winner?.status ?? .ready, sources: sources
            )
        )
        emit(.upserted([merged]))
        return true
    }

    /// Правило слияния C-005, шаги 1-6, дословно (инв. 10 — то же правило действует и МЕЖДУ
    /// циклами, на снимках, а не только на пакете одного цикла). Разбито на несколько
    /// маленьких функций — `function_body_length`, тот же приём, что уже стоит по всему
    /// модулю (`Harness.seedAndInitialize` и соседи, MEE-362 ч.2).
    private static func merge(sources: [MeetingSource], id: UUID) throws -> MeetingEvent {
        let identityWinner = Self.identityWinner(among: sources)
        let (contentWinner, otherPayloads) = try Self.contentWinner(among: sources, identityWinner: identityWinner)
        let attendees = Self.mergedAttendees(winner: contentWinner, others: otherPayloads)

        // Шаг 2: скаляр победителя содержимого; nil (только у четырёх опциональных полей —
        // остальные шесть не optional в MeetingEventPayload и nil не бывают) — первое не-nil
        // значение остальных источников в порядке возрастания sourceConnectorId.
        func firstNonNil<Value>(_ ownValue: Value?, _ pick: (MeetingEventPayload) -> Value?) -> Value? {
            ownValue ?? otherPayloads.lazy.compactMap(pick).first
        }

        return try MeetingEvent(
            id: id,
            // Шаг 6/инв. 10: sourceConnectorId/externalId/icalUid — identity, от победителя
            // шага 1, независимо от того, есть ли у него снимок содержимого.
            sourceConnectorId: identityWinner.sourceConnectorId,
            externalId: identityWinner.externalId,
            icalUid: identityWinner.icalUid,
            title: contentWinner.title,
            start: contentWinner.start,
            end: contentWinner.end,
            timeZone: contentWinner.timeZone,
            isAllDay: contentWinner.isAllDay,
            isCancelled: contentWinner.isCancelled,
            organizer: firstNonNil(contentWinner.organizer) { $0.organizer },
            attendees: attendees,
            location: firstNonNil(contentWinner.location) { $0.location },
            bodyText: firstNonNil(contentWinner.bodyText) { $0.bodyText },
            conference: firstNonNil(contentWinner.conference) { $0.conference },
            // Шаг 5: lastModified результата — максимум по слитым событиям, то есть ровно
            // lastModified победителя шага 1 (он и есть максимум по построению шага 1).
            lastModified: identityWinner.lastModified
        )
    }

    /// Шаг 1: наибольший `lastModified`, тай-брейк — лексикографически меньший
    /// `sourceConnectorId`. Участвуют ВСЕ источники, со снимком или без (инв. 10) — identity
    /// известна независимо от наличия снимка содержимого.
    private static func identityWinner(among sources: [MeetingSource]) -> MeetingSource {
        sources.min { lhs, rhs in
            lhs.lastModified != rhs.lastModified
                ? lhs.lastModified > rhs.lastModified
                : lhs.sourceConnectorId < rhs.sourceConnectorId
        }!
    }

    /// Источники со снимком — вклад в шаги 2-3 (инв. 10: строка без снимка в шаги 2-3 не
    /// вкладывается вовсе). Победитель СОДЕРЖИМОГО — снимок победителя identity, если он
    /// есть; иначе первый источник со снимком в порядке возрастания `sourceConnectorId` — та
    /// же подстановка, что нужна внутри шага 2 на отдельном nil-поле победителя, только сразу
    /// на все десять полей разом.
    private static func contentWinner(
        among sources: [MeetingSource], identityWinner: MeetingSource
    ) throws -> (winner: MeetingEventPayload, others: [MeetingEventPayload]) {
        let withPayload = sources.filter { $0.payload != nil }.sorted { $0.sourceConnectorId < $1.sourceConnectorId }
        let winnerConnectorId: String
        let winnerPayload: MeetingEventPayload
        if let payload = identityWinner.payload {
            winnerPayload = payload
            winnerConnectorId = identityWinner.sourceConnectorId
        } else if let first = withPayload.first, let payload = first.payload {
            winnerPayload = payload
            winnerConnectorId = first.sourceConnectorId
        } else {
            // Не случается из applyIncoming (свежий payload — всегда хотя бы один снимок) —
            // функция остаётся тотальной, а не падает безмолвным крашем на пустом входе.
            throw StorageError.constraintViolation(message: "слияние без единого снимка невозможно (инв. 10 C-005)")
        }
        let others = withPayload.filter { $0.sourceConnectorId != winnerConnectorId }.compactMap(\.payload)
        return (winnerPayload, others)
    }

    /// Шаг 3: объединение по email (на совпадении побеждает запись победителя содержимого —
    /// он идёт в списке первым); участник без email добавляется, только если его `name` не
    /// совпадает с уже добавленным.
    private static func mergedAttendees(
        winner: MeetingEventPayload, others: [MeetingEventPayload]
    ) -> [MeetingEvent.Attendee] {
        var attendees: [MeetingEvent.Attendee] = []
        var seenEmails: Set<String> = []
        var seenNames: Set<String> = []
        for payload in [winner] + others {
            for attendee in payload.attendees {
                if let email = attendee.person.email {
                    guard !seenEmails.contains(email) else { continue }
                    seenEmails.insert(email)
                    attendees.append(attendee)
                    if let name = attendee.person.name { seenNames.insert(name) }
                } else if let name = attendee.person.name {
                    guard !seenNames.contains(name) else { continue }
                    seenNames.insert(name)
                    attendees.append(attendee)
                } else {
                    attendees.append(attendee)
                }
            }
        }
        return attendees
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
        let remaining = record.sources.filter {
            !($0.sourceConnectorId == source.rawValue && $0.externalId == externalId)
        }
        // Возврат РП (MEE-385, инв. 10 C-005): К65 вход Б — источник теряется у
        // многоисточниковой встречи. Identity (sourceConnectorId/externalId/icalUid)
        // ПЕРЕСЧИТЫВАЕТСЯ ВСЕГДА шагом 1 (наибольший lastModified среди оставшихся
        // строк, тай-брейк — лексикографически меньший sourceConnectorId), даже когда
        // ушедший источник был identity и снимков (`MeetingSource.payload`) у оставшихся
        // сегодня ещё нет ни у одного (перенос payload в applyIncoming — следующий шаг
        // этой же задачи). Без пересчёта, если ушедший источник был identity, `save`
        // бросает constraintViolation: `sourcesIncludingOwnIdentity` (storage) не находит
        // identity `event` среди `remaining` и синтезировать её не вправе (инв. 31 C-010
        // v18 — синтез снимка собственной identity разрешён только при первом сохранении
        // с одним источником, не здесь).
        //
        // Содержимое (шаги 2-3 — title/start/…/conference) НЕ пересчитывается тем же
        // инвариантом 10, пока ни у одного оставшегося источника нет снимка: `event`
        // остаётся тем, каким был, кроме identity-полей. Полное слияние по снимкам —
        // применится само, как только applyIncoming начнёт переносить `payload` (следующий
        // коммит этой же задачи, MEE-385).
        let recomputedEvent = try Self.recomputingIdentity(of: record.event, remaining: remaining)
        try await meetingRepository.save(
            MeetingRecord(
                event: recomputedEvent, dedupKey: DedupKey.make(from: recomputedEvent),
                status: record.status, sources: remaining
            )
        )
        return false
    }

    /// Шаг 1 правила слияния C-005 (наибольший `lastModified`, тай-брейк — лексикографически
    /// меньший `sourceConnectorId`) над IDENTITY-полями (`sourceConnectorId`/`externalId`/
    /// `icalUid`) оставшихся источников — инв. 10 C-005 требует пересчёта identity всегда,
    /// независимо от того, пересчитывается ли содержимое. `remaining` непусто по построению
    /// (вызывающая сторона уже отделила случай `count <= 1` до вызова).
    private static func recomputingIdentity(of event: MeetingEvent, remaining: [MeetingSource]) throws -> MeetingEvent {
        let winner = remaining.min { lhs, rhs in
            lhs.lastModified != rhs.lastModified
                ? lhs.lastModified > rhs.lastModified
                : lhs.sourceConnectorId < rhs.sourceConnectorId
        }!
        guard winner.sourceConnectorId != event.sourceConnectorId
            || winner.externalId != event.externalId
            || winner.icalUid != event.icalUid
        else {
            return event
        }
        return try MeetingEvent(
            id: event.id, sourceConnectorId: winner.sourceConnectorId, externalId: winner.externalId,
            icalUid: winner.icalUid, title: event.title, start: event.start, end: event.end,
            timeZone: event.timeZone, isAllDay: event.isAllDay, isCancelled: event.isCancelled,
            organizer: event.organizer, attendees: event.attendees, location: event.location,
            bodyText: event.bodyText, conference: event.conference, lastModified: event.lastModified
        )
    }
}
