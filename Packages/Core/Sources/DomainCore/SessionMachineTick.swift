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
        for input in mailbox.drain() {
            switch input {
            case let .signal(signal):
                remember(signal)
            case let .calendar(change):
                apply(change)
            case let .capture(event):
                // Событие КЛАДЁТСЯ, а переход по нему читается фазой сроков в порядке
                // строк §7: разбор и цена — в шапке `SessionMachineProcessing.swift`.
                arrivedCapture.append(event)
            case let .job(event):
                arrivedJobs.append(event)
            case .power:
                // `willSleep` записи не останавливает и состояния не меняет (§9.3, К69);
                // `didWake` зовёт `reschedule(now:)` — это `Scheduler`, часть C. Оба входа
                // состояния не меняют и ошибки не дают (инвариант 2, тотальность).
                continue
            }
        }
        refreshSessionEvents()
        return await openSessions(now: now)
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
    func openSessions(now: Date) async -> [UUID] {
        await readStorage(now: now)

        var opened: [UUID] = []
        for event in knownEvents.values.sorted(by: { SessionMachineOrder.ascending($0.id, $1.id) }) {
            guard !deletedEvents.contains(event.id) else { continue }
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
            // Спор — не выбор (§5.4): цель, отнесённая к нескольким сессиям сразу, не
            // является звучащей целью НИ ОДНОЙ из них, пока спрос не разрешён. Это и есть
            // единственное чтение, при котором обе половины §5.4 истинны разом: «до ответа
            // не записывает ни одна» и «нет ответа — каждая уходит в `skipped` по своему
            // `graceEndsAt`» (строка 9 читает клаузу «звучащей цели нет»).
            let chosen = SessionMachineRules.soundingTargetSignal(
                among: related.filter { !disputed.contains($0.group?.appKey ?? "") },
                sessionProvider: session.event?.conference?.provider
            )
            session.target = chosen?.group ?? adHocTarget(for: session, now: now)
            if let observedAt = chosen?.observedAt {
                session.lastTargetObservedAt = observedAt
            } else if let appKey = session.target?.appKey,
                      let signal = actualSignal(appKey: appKey, now: now) {
                session.lastTargetObservedAt = signal.observedAt
            }
            session.estimate = SessionMachineRules.estimate(over: related)
            session.updatedAt = now
            store[identifier] = session
        }
    }

    /// Цель ad-hoc-сессии до входа в запись.
    ///
    /// НАЗВАНО, А НЕ УМОЛЧАНО: правила §5.4 не относят к такой сессии ни одного сигнала —
    /// правила 2 и 3 требуют либо окна события (`armAt ≤ now ≤ graceEndsAt`), которого у
    /// ad-hoc нет, либо состояния из `{recording, stopping}`, в которое она ещё не вошла.
    /// То есть §5.4 и §8.6 отвечают на разные вопросы, а не спорят: §5.4 распределяет
    /// сигналы между сессиями СОБЫТИЙ, а ad-hoc есть вход для цели, которую он никому не
    /// отдал (правило 4). Цель такой сессии поэтому держится её `appKey` и проверяется на
    /// актуальность прямо — ровно то, что §8.6 называет причиной спроса.
    private func adHocTarget(for session: SessionMachineSession, now: Date) -> ProcessGroup? {
        guard session.origin == .adHoc, let appKey = session.adHocAppKey else { return nil }
        return actualSignal(appKey: appKey, now: now)?.group
    }

    /// То, что правило §5.4 читает у сессии.
    func side(of session: SessionMachineSession) -> SessionMachineRules.SessionSide {
        SessionMachineRules.SessionSide(
            meetingId: session.meetingId,
            state: session.state,
            provider: session.event?.conference?.provider,
            deadlines: session.event.map { SessionMachineRules.arm(for: $0, settings: settings) }
        )
    }

    /// Сигналы, отнесённые к сессии (§5.4) и актуальные (C-009 §1), вместе с её собственным
    /// календарным сигналом (§5.2). Календарный сигнал строится здесь и здесь же
    /// потребляется: в поток `signals()` он не уходит.
    func relatedSignals(for session: SessionMachineSession, now: Date) -> [MeetingSignal] {
        let deadlines = session.event.map { SessionMachineRules.arm(for: $0, settings: settings) }
        var related = signals.values
            .filter { SessionMachineRules.isActual($0, now: now, weights: weights) }
            .filter {
                SessionMachineRules.relates(
                    signal: $0,
                    to: SessionMachineRules.SessionSide(
                        meetingId: session.meetingId,
                        state: session.state,
                        provider: session.event?.conference?.provider,
                        deadlines: deadlines
                    ),
                    now: now
                )
            }
        if let event = session.event,
           let own = SessionMachineRules.calendarSignal(
               for: event, origin: session.origin, weights: weights, now: now
           ) {
            related.append(own)
        }
        return related
    }
}
