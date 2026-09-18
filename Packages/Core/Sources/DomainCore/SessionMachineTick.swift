//  Ход времени машины сессий: фазы одного `tick(now:)` — контракт C-018 (MEE-276),
//  §«Поведение» («сперва применяются пришедшие события, затем пересчитывается оценка и
//  звучащая цель, затем проверяются сроки в порядке строк §7»), §9.1 и §8.2.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ A задачи MEE-298. Файл отделён от `SessionMachine.swift` по одному доводу и он
//  механический: `--strict` линта считает файл длиннее четырёхсот строк нарушением, а
//  порядок фаз §«Поведение» стоит объяснять там же, где он исполняется. Путями машины
//  остаются `Sources/DomainCore/SessionMachine*.swift` — признак не тронут.
//
//  Обращения к состоянию актора остаются внутримодульными: расширение в другом файле
//  `private` не видит, и потому хранимые члены объявлены без модификатора. Наружу это не
//  выходит ни на символ — публичной остаётся только поверхность протокола §3.1.

import Foundation

extension SessionMachine {
    // MARK: - Фаза 1: пришедшие события и заведение

    /// Применяет всё, что легло в ящик между двумя `tick`, затем заводит сессии по §9.1.
    /// Возвращает идентификаторы заведённых: их снимки публикуются после пересчёта цели.
    func applyArrivals(now: Date) async -> [UUID] {
        absorbArrivals()
        // `willSleep` записи не останавливает и состояния не меняет (§9.3, К69).
        // `didWake` зовёт `reschedule(now:)` — и ЗДЕСЬ, а не своим ходом: §9.3 называет за
        // ним ещё и `tick(now:)`, а машина не имеет ни таймера, ни часов (К9) и разбудить
        // себя не может ничем. Событие приходит в ящик, ближайший `tick` его применяет —
        // этот самый, — и `reschedule` идёт первой фазой, прежде сроков. Сроки, пройденные
        // во сне, исполняет тот же `tick` фазой 3, и это инвариант 14 дословно: второго
        // механизма для сна не заводится ни одного (К68, К86 вид (ii)).
        let woke = arrivedPower.contains { $0 == .didWake }
        arrivedPower.removeAll()
        if woke { await reschedule(now: now) }
        return await openSessions(now: now)
    }

    /// Взять из ящика всё, что в нём лежит, и положить в состояние, которое читают правила.
    ///
    /// СОСТОЯНИЯ НИ ОДНОЙ СЕССИИ ЭТО НЕ МЕНЯЕТ, И ПОТОМУ ЗОВУТ ЕГО ДВОЕ: фаза 1 хода
    /// времени и КАЖДАЯ КОМАНДА §3.1. Довод — не удобство, а §7 и §8.6 вместе. Команда
    /// исполняется В МОМЕНТ ВЫЗОВА, а условие заведения §8.6 стоит на том, ЕСТЬ ЛИ ТАКОЙ
    /// СИГНАЛ; сигнал же приходит потоком и лежит в ящике до ближайшего `tick`. Команда,
    /// не забравшая ящик, отвечает `nothingToRecord` на созвон, который в эту минуту
    /// звучит, — и вектор К95 (б′) «команда подана ДО первого `tick` по этому сигналу»
    /// не подать было бы нечем: он неисполним ни одной такой реализацией.
    ///
    /// ГРАНИЦА НАЗВАНА, И ОНА ЕСТЬ ВЕСЬ СМЫСЛ РАЗВЕДЕНИЯ: здесь нет ни одного перехода, ни
    /// одного заведения и ни одной публикации. `CaptureEvent` и `JobEvent` только
    /// КЛАДУТСЯ — строки 11—15 читает фаза сроков, в порядке таблицы, — и потому вход,
    /// пришедший между двумя `tick`, состояния не меняет и после команды тоже (К86, вид
    /// (ii)). Переставить эти два ответа местами нельзя: К45 (iv) требует, чтобы строка 10
    /// побеждала строку 11, а она читается фазой сроков.
    func absorbArrivals() {
        for input in mailbox.drain() {
            switch input {
            case let .signal(signal):
                remember(signal)
            case let .calendar(change):
                apply(change)
            case let .capture(event):
                arrivedCapture.append(event)
            case let .job(event):
                arrivedJobs.append(event)
            case let .power(event):
                arrivedPower.append(event)
            }
        }
        refreshSessionEvents()
    }

    /// §9.2: изменившееся событие меняет сроки своей сессии НА МЕСТЕ. Сроки нигде не
    /// хранятся — они функция от события и настроек, — и потому «пересчитать» значит
    /// подставить сессии действующее событие, а не тронуть пять полей порознь.
    func refreshSessionEvents() {
        for identifier in Array(store.keys) {
            guard var session = store[identifier],
                  let meetingId = session.meetingId,
                  let event = knownEvents[meetingId] else { continue }
            session.event = event
            store[identifier] = session
        }
    }

    /// Слияние идёт по парам «вид + источник»: держится последний по `observedAt`.
    func remember(_ signal: MeetingSignal) {
        let key = SessionMachineRules.pair(of: signal)
        if let known = signals[key], known.observedAt > signal.observedAt { return }
        signals[key] = signal
    }

    func apply(_ change: CalendarChange) {
        switch change {
        case let .upserted(events):
            for event in events {
                knownEvents[event.id] = event
                deletedEvents.remove(event.id)
            }
        case let .deleted(identifiers):
            deletedEvents.formUnion(identifiers)
        }
    }

    /// Заведение по §9.1: одно условие, три состояния по `now` (строки 1, 1а, 1б).
    ///
    /// - Parameters:
    ///   - readingStorage: читать ли хранилище прежде заведения. `false` зовёт
    ///     восстановление §10: оно уже прочло встречи своим перечнем Б, и второе чтение
    ///     легло бы в журнал вызовов лишней парой, которую К78 наблюдает порядком.
    ///   - limitedTo: встречи, которым заведение разрешено; `nil` — всем известным.
    ///     Ограничение несёт восстановление §10: перечень Б заводит по §9.1 ТОЛЬКО встречи
    ///     в `scheduled`, `armed` и `awaitingSignal` — первой своей строкой, — а судьбу
    ///     встреч в `recording`, `stopping` и `processing` решает перечень А, и второго
    ///     заведения для них у §10 нет ни одного (К78, К79).
    func openSessions(
        now: Date,
        readingStorage: Bool = true,
        limitedTo: Set<UUID>? = nil
    ) async -> [UUID] {
        if readingStorage { await readStorage(now: now) }

        var opened: [UUID] = []
        for event in knownEvents.values.sorted(by: { SessionMachineOrder.ascending($0.id, $1.id) }) {
            guard !deletedEvents.contains(event.id) else { continue }
            if let limitedTo, !limitedTo.contains(event.id) { continue }
            let hasLive = store.values.contains { $0.meetingId == event.id && !$0.state.isTerminalSession }
            guard SessionMachineRules.mayOpenSession(
                event: event,
                storedStatus: storedStatuses[event.id],
                hasLiveSession: hasLive,
                settings: settings,
                now: now
            ) else { continue }
            guard let state = SessionMachineRules.openingState(
                event: event, settings: settings, now: now
            ) else { continue }

            let identifier = UUID()
            store[identifier] = SessionMachineSession(
                sessionId: identifier,
                origin: .scheduled,
                meetingId: event.id,
                state: state,
                recordingId: nil,
                target: nil,
                estimate: 0,
                enteredStateAt: now,
                updatedAt: now,
                event: event,
                promptId: nil,
                recordAnswered: false,
                commandGaveTarget: false,
                adHocAppKey: nil,
                lastTargetObservedAt: nil,
                powerToken: nil
            )
            opened.append(identifier)
        }
        return opened.sorted(by: SessionMachineOrder.ascending)
    }

    /// Хранилище даёт хранимый `MeetingStatus` (клауза инварианта 24) и те события, которых
    /// машина ещё не видела. Содержимое известного события хранилищем не переписывается:
    /// о его изменениях говорит `CalendarPort.changes()` (§2, §9.2).
    ///
    /// Окно чтения есть окно §9.1 дословно: `now ≤ graceEndsAt` равносильно
    /// `e.start ≥ now − missingSignalGraceSeconds`, а сверху §9.1 границы не ставит —
    /// строка 1 заводит сессию при `now < armAt` на любом удалении события.
    func readStorage(now: Date) async {
        let from = now.addingTimeInterval(-TimeInterval(settings.missingSignalGraceSeconds))
        guard let records = try? await meetings.meetings(from: from, to: Date.distantFuture) else { return }
        for record in records {
            storedStatuses[record.event.id] = record.status
            if knownEvents[record.event.id] == nil {
                knownEvents[record.event.id] = record.event
            }
        }
    }

    // MARK: - Фаза 2: оценка и звучащая цель

    func recompute(now: Date) {
        contested = contestedTargets(now: now)
        let disputed = Set(contested.keys)
        for identifier in Array(store.keys) {
            guard var session = store[identifier], !session.state.isTerminalSession else { continue }
            let related = relatedSignals(for: session, now: now)
            let chosen = SessionMachineRules.soundingTargetSignal(
                among: targetCandidates(among: related, disputed: disputed),
                sessionProvider: session.event?.conference?.provider
            )
            session.target = chosen?.group
            if let observedAt = chosen?.observedAt {
                session.lastTargetObservedAt = observedAt
            }
            session.estimate = SessionMachineRules.estimate(over: related.map(\.signal))
            session.updatedAt = now
            store[identifier] = session
        }
    }

    /// Сигналы, из которых §5.3 выбирает звучащую цель: отнесённые к сессии, за вычетом
    /// ОСПАРИВАЕМЫХ.
    ///
    /// Спор — не выбор (§5.4): цель, отнесённая к нескольким сессиям сразу, не является
    /// звучащей целью НИ ОДНОЙ из сторон, пока спрос не разрешён. Это и есть единственное
    /// чтение, при котором обе половины §5.4 истинны разом: «до ответа не записывает ни
    /// одна» и «нет ответа — каждая уходит в `skipped` по своему `graceEndsAt`» (строка 9
    /// читает клаузу «звучащей цели нет»).
    ///
    /// ВЫЧЕТ ИДЁТ ПО ОТНЕСЕНИЮ, А НЕ ПО ОДНОМУ `appKey`, И ЭТО НЕСУЩЕЕ. Сторонами спора
    /// §5.4 называет сессии, к которым сигнал отнесён правилом 2 либо правилом 3; сессия,
    /// получившая его правилом `1а`, стороной не является, и спор её «не касается»
    /// дословно. Реализация, снимающая спорный `appKey` у всех подряд, гасит цель
    /// ad-hoc-сессии чужим спором — то есть уводит в `skipped` строкой 9 сессию, которая
    /// пишет или вот-вот запишет (К94, клауза Входа «держателем выступает ad-hoc-сессия»).
    private func targetCandidates(
        among related: [RelatedSignal],
        disputed: Set<String>
    ) -> [MeetingSignal] {
        related
            .filter { item in
                guard item.relation.isDisputeParty else { return true }
                return !disputed.contains(item.signal.group?.appKey ?? "")
            }
            .map(\.signal)
    }

    /// То, что правило §5.4 читает у сессии. Одно место на все три чтения — отнесение,
    /// спор и заведение ad-hoc: три копии этой пятёрки разошлись бы на первой же правке.
    func side(of session: SessionMachineSession) -> SessionMachineRules.SessionSide {
        SessionMachineRules.SessionSide(
            meetingId: session.meetingId,
            origin: session.origin,
            state: session.state,
            provider: session.event?.conference?.provider,
            deadlines: session.event.map { SessionMachineRules.arm(for: $0, settings: settings) },
            adHocAppKey: session.adHocAppKey
        )
    }

    /// Сигнал вместе с правилом §5.4, которым он отнесён к сессии.
    struct RelatedSignal {
        let signal: MeetingSignal
        let relation: SessionMachineRules.Relation
    }

    /// Сигналы, отнесённые к сессии (§5.4) и актуальные (C-009 §1), вместе с её собственным
    /// календарным сигналом (§5.2). Календарный сигнал строится здесь и здесь же
    /// потребляется: в поток `signals()` он не уходит.
    func relatedSignals(for session: SessionMachineSession, now: Date) -> [RelatedSignal] {
        let sessionSide = side(of: session)
        var related = signals.values
            .filter { SessionMachineRules.isActual($0, now: now, weights: weights) }
            .compactMap { signal -> RelatedSignal? in
                SessionMachineRules.relation(signal: signal, to: sessionSide, now: now)
                    .map { RelatedSignal(signal: signal, relation: $0) }
            }
        if let event = session.event,
           let own = SessionMachineRules.calendarSignal(
               for: event, origin: session.origin, weights: weights, now: now
           ) {
            related.append(RelatedSignal(signal: own, relation: .rule1Calendar))
        }
        return related
    }
}
