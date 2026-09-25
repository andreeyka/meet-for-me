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

    /// Инв. 11 (C-005, MEE-385): слияние ЛЮБЫХ двух входящих событий (и `applyIncoming`, и
    /// `applyDeletedExternalId` — оба переустраивают `sources`/`event` одной и той же
    /// встречи) сериализуется — ОДНА общая цепочка задач на весь актор (`mergeTail`), не
    /// словарь по дедуп-ключу входящего события.
    ///
    /// Возврат РП (приёмка #105): словарь по ключу был неверен ДВАЖДЫ. (1) Ключ входящего
    /// события известен только СНАЧАЛА тела (`DedupKey.make(from:)` от временно
    /// присвоенного id) — если два источника одной существующей встречи в одном цикле
    /// вычисляют разные ключи (например, второй ещё не находит запись через
    /// `meeting(dedupKey:)`, пока первый её уже не сохранил под другим ключом), они
    /// сериализуются на РАЗНЫЕ записи словаря и всё равно гонятся друг с другом.
    /// (2) `applyDeletedExternalId` вообще не заводил ключ — `dedupKey == nil` пропускал
    /// сериализацию целиком (старый `guard let dedupKey else { return try await body() }`).
    /// Слияния короткие (один `await meetingRepository.save`/`.meeting` внутри) — цена
    /// полной сериализации всех встреч актора разом ничтожна, а корректность не зависит от
    /// того, на какой ключ разошлись два события ДО слияния.
    func serialized<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = mergeTail
        // Task<T, Error> (обычный, «сырой» throws), не Task<Result<T, Error>, Never>: голый
        // `Error` не Sendable, Result<T, Error> с ним тоже не Sendable — Task этого от
        // Success (T) требует, но не от Failure (`Task<Success, Failure> where Success:
        // Sendable, Failure: Error` — без Sendable у Failure), так что throws-задача сама по
        // себе, без ручной упаковки в Result, — верный и более простой путь.
        let task = Task<T, Error> {
            _ = await previous?.value
            return try await body()
        }
        mergeTail = Task { _ = try? await task.value }
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
        try await serialized {
            try await self.mergeIncoming(payload: payload)
        }
    }

    /// К19 (перечень MEE-347, C-005 v14 правило слияния п.4, признаки а/б, коллизия двух
    /// кандидатов): признак (а) (по вычисленному `DedupKey` payload'а) и признак (б) (по паре
    /// `sourceConnectorId`/`externalId` ТОГО ЖЕ payload'а) находят ДВЕ РАЗНЫЕ существующие
    /// записи — обе уже отдельно несут часть одной и той же реальной встречи. Побеждает
    /// запись с лексикографически меньшим `id.uuidString`; источники проигравшей переходят
    /// победителю, её `id` публикуется `.deleted` (К39 вход А — коллизия признаков — один из
    /// санкционированных поводов для `.deleted`, наравне с уходом единственного источника
    /// многоисточниковой встречи, К65 вход А).
    ///
    /// СТРОКА (возврат РП, 24.09, MEE-361 22:57 UTC — буквальное прочтение по явному
    /// разрешению, передано архитектору на уточнение формулировки): перечень описывает вход
    /// как «признак (а) не дал ничего; признак (б) находит два кандидата по разным
    /// источникам входного события». Прямого кода-пути для «два РАЗНЫХ входящих источника»
    /// нет: `mergeTail` (инв. 11) полностью сериализует обработку — если у обоих входящих
    /// payload'ов один и тот же `DedupKey`, второй по счёту всегда находит результат первого
    /// через признак (а) (коллизии нет, это штатное присоединение источника); а если общего
    /// `DedupKey` нет ни у одного, семантической связи между двумя раздельными записями нет
    /// вовсе — сливать нечего. Единственный РЕАЛЬНО ДОСТИЖИМЫЙ код-путь, где `MeetingRepository.
    /// save` иначе бросил бы `constraintViolation` (инв. 30 C-010 — пара уже занята другой
    /// записью): признак (а) находит одну запись, а признак (б) по паре ЭТОГО ЖЕ payload'а —
    /// другую. Реализовано так.
    private func mergeIncoming(payload: MeetingEventPayload) async throws -> Bool {
        let provisional = try payload.assigningId(UUID())
        let dedupKey = DedupKey.make(from: provisional)
        var byKey: MeetingRecord?
        if let dedupKey {
            byKey = try await meetingRepository.meeting(dedupKey: dedupKey)
        }
        let byPair = try await meetingRepository.meeting(
            sourceConnectorId: payload.sourceConnectorId, externalId: payload.externalId
        )

        var winner = byKey ?? byPair
        var absorbed: MeetingRecord?
        if let byKey, let byPair, byKey.event.id != byPair.event.id {
            (winner, absorbed) = byKey.event.id.uuidString < byPair.event.id.uuidString
                ? (byKey, byPair) : (byPair, byKey)
        }

        let newSource = MeetingSource(
            sourceConnectorId: payload.sourceConnectorId, externalId: payload.externalId,
            icalUid: payload.icalUid, lastModified: payload.lastModified, payload: payload
        )
        var sources = ((winner?.sources ?? []) + (absorbed?.sources ?? [])).filter {
            !($0.sourceConnectorId == newSource.sourceConnectorId && $0.externalId == newSource.externalId)
        }
        sources.append(newSource)

        let id = winner?.event.id ?? UUID()
        let merged = try Self.merge(sources: sources, id: id)
        // Проигравшая запись обязана уйти ДО save() победителя — иначе её всё ещё живая
        // строка той же пары (sourceConnectorId, externalId) столкнётся с только что
        // унаследованной инв. 30 C-010 ("пара уже занята другой записью").
        //
        // СТРОКА (возврат РП, 24.09 23:12 UTC, п. 1): delete()+save() не атомарны — бросит
        // save() ПОСЛЕ того, как delete() уже прошёл, проигравшая запись потеряется без
        // следа (не восстановится следующим циклом: её источники уже нигде не значатся).
        // `MeetingRepository` (C-010, DomainCore/Repositories.swift) не даёт ни
        // транзакции, ни объединённого метода «удалить+сохранить одной операцией» — обратный
        // порядок (save() до delete()) не чинит это, а меняет отказ на другой (инв. 30
        // выше): настоящая атомарность требует новой операции репозитория, зона C-010,
        // владелец DEV-2 — не мой код-путь; вынесено в MEE-386 на IR архитектору.
        if let absorbedId = absorbed?.event.id {
            try await meetingRepository.delete(meetingIds: [absorbedId])
        }
        try await meetingRepository.save(
            MeetingRecord(
                event: merged, dedupKey: DedupKey.make(from: merged),
                status: winner?.status ?? .ready, sources: sources
            )
        )
        if let absorbedId = absorbed?.event.id {
            emit(.deleted([absorbedId]))
        }
        emit(.upserted([merged]))
        return true
    }

    /// Правило слияния C-005, шаги 1-6, дословно (инв. 10 — то же правило действует и МЕЖДУ
    /// циклами, на снимках, а не только на пакете одного цикла). Разбито на несколько
    /// маленьких функций — `function_body_length`, тот же приём, что уже стоит по всему
    /// модулю (`Harness.seedAndInitialize` и соседи, MEE-362 ч.2). Не `private`:
    /// `CalendarPortImplMerge+SourceDeparture.swift` тоже зовёт — `private` в Swift видна
    /// только внутри своего ФАЙЛА, а тип теперь на два файла.
    static func merge(sources: [MeetingSource], id: UUID) throws -> MeetingEvent {
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

    // К65 вход А/Б — источник теряется у записи — `CalendarPortImplMerge+SourceDeparture.swift`
    // (тот же приём file_length/type_body_length, что развёл этот файл и `CalendarPortImplSync.swift`).
}
