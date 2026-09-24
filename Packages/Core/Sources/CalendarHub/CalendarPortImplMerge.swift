//  CalendarPortImpl+Merge — IR-126 (MEE-372/MEE-385): перенос снимков источников между
//  циклами синхронизации и слияние шагами 1-6 C-005 (инв. 10/11).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен
//
//  Вынесено из CalendarPortImplSync.swift отдельным файлом — та же причина, что вынесла
//  сам CalendarPortImplSync.swift из CalendarPortImpl.swift (см. его шапку): SwiftLint
//  `file_length`/`type_body_length` считают КАЖДОЕ расширение типа отдельно, а не суммой
//  по всем файлам модуля — актор остаётся одним типом, просто с ещё одной лексической
//  областью.

import Foundation
import DomainCore

extension CalendarPortImpl {

    /// Инв. 11 (C-005, MEE-385): слияние ДВУХ входящих событий ОДНОЙ встречи (тот же дедуп-
    /// ключ) сериализуется — очередь задач на ключ (`mergeTail`), атомарно или строгим
    /// порядком, так что конкурентное чтение-запись двух таких событий не теряет ни одно.
    /// Разные встречи сливаются независимо и параллельно, как и раньше — нет записи в
    /// словаре под их ключом, нет и ожидания. `TaskGroup` (`sync(trigger:)`, один `Task` на
    /// источник) плюс реентерабельность актора на `await` иначе могут перекрыть запись
    /// одного входящего события записью другого, ещё не слитого с ним.
    func serialized<T: Sendable>(
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
    func applyIncoming(payload: MeetingEventPayload) async throws -> Bool {
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

    func applyDeletedExternalId(source: CalendarSourceId, externalId: String) async throws -> Bool {
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
        // ушедший источник был identity. Содержимое (шаги 2-3) пересчитывается тем же
        // инвариантом 10 только если у оставшихся источников есть снимок (не решено этим
        // коммитом — applyIncoming уже переносит payload, но эта ветвь до полного
        // слияния пока не доведена; событие остаётся с прежним содержимым, identity —
        // всегда свежая). Без пересчёта identity, если ушедший источник был identity,
        // `save` бросает constraintViolation: `sourcesIncludingOwnIdentity` (storage) не
        // находит identity `event` среди `remaining` и синтезировать её не вправе (инв. 31
        // C-010 v18 — синтез снимка собственной identity разрешён только при первом
        // сохранении с одним источником, не здесь).
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
