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
            case .capture, .job, .power:
                // Ни одна строка таблицы части A этих входов не называет: состояния не
                // меняются и ошибки не даётся (инвариант 2, тотальность).
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
                recordAnswered: false
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
            session.target = SessionMachineRules.soundingTarget(
                among: related.filter { !disputed.contains($0.group?.appKey ?? "") },
                sessionProvider: session.event?.conference?.provider
            )
            session.estimate = SessionMachineRules.estimate(over: related)
            session.updatedAt = now
            store[identifier] = session
        }
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
                    sessionMeetingId: session.meetingId,
                    sessionState: session.state,
                    sessionProvider: session.event?.conference?.provider,
                    deadlines: deadlines,
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

    // MARK: - Фаза 3: сроки в порядке строк §7

    /// Строки проверяются до неподвижной точки: срок, пройденный во сне, исполняется ПЕРВЫМ
    /// `tick` после него, а не по одному переходу на `tick` (инвариант 14, К11, К31).
    /// Предел обхода — число состояний перечисления: больше переходов подряд одной сессии
    /// таблица дать не может, а цикла строки части A не образуют (строка 5 уводит в
    /// `scheduled`, откуда строка 2 при том же `now` ложна).
    func runDeadlines(now: Date) async {
        for identifier in store.keys.sorted(by: SessionMachineOrder.ascending) {
            var steps = 0
            while steps < 9 {
                steps += 1
                guard let session = store[identifier], !session.state.isTerminalSession else { break }
                let deadlines = session.event.map { SessionMachineRules.arm(for: $0, settings: settings) }
                let gone = isGone(session)
                guard let row = SessionMachineRules.deadlineRow(
                    state: session.state,
                    deadlines: deadlines,
                    eventGone: gone,
                    hasSoundingTarget: session.target != nil,
                    now: now
                ) else { break }
                do {
                    try await transition(identifier, to: row.target, now: now)
                } catch {
                    // Исход не записан — значит перехода не было (инвариант 18). Срок
                    // наступит на следующем `tick`: терять решение молча дороже, чем ждать.
                    break
                }
            }
        }
    }

    func isGone(_ session: SessionMachineSession) -> Bool {
        guard let meetingId = session.meetingId else { return false }
        if deletedEvents.contains(meetingId) { return true }
        return knownEvents[meetingId]?.isCancelled ?? session.event?.isCancelled ?? false
    }

    // MARK: - §8.2: спрос при политике `.ask`

    /// Спрос поднимается в момент `askAt`, а у сессии, заведённой при уже прошедшем `askAt`,
    /// — в момент заведения: срок не «догоняется» и не пропускается.
    func raiseDuePrompts(now: Date) {
        guard settings.recordingPolicy == .ask else { return }
        for identifier in store.keys.sorted(by: SessionMachineOrder.ascending) {
            guard var session = store[identifier] else { continue }
            guard !session.state.isTerminalSession, session.promptId == nil, !session.recordAnswered else {
                continue
            }
            guard let event = session.event else { continue }
            guard let askAt = SessionMachineRules.arm(for: event, settings: settings).askAt else { continue }
            guard now >= askAt else { continue }

            let prompt = SessionPrompt(
                promptId: UUID(),
                sessionId: identifier,
                kind: .recordThisMeeting,
                raisedAt: now,
                expiresAt: nil
            )
            session.promptId = prompt.promptId
            store[identifier] = session
            raised[prompt.promptId] = (prompt: prompt, isWithdrawn: false)
            promptOrder.append(prompt.promptId)
            hub.publish(.promptRaised(prompt))
        }
    }

    // MARK: - §5.4: спор о звучащей цели

    /// Цели, отнесённые сразу к двум и более живым сессиям: `appKey` → кандидаты по
    /// возрастанию `sessionId`. Правило 2, отнёсшее цель ровно к одной сессии, спора не
    /// даёт — счёт отнесённых его и различает.
    func contestedTargets(now: Date) -> [String: [UUID]] {
        let live = store.values.filter { !$0.state.isTerminalSession }
        var found: [String: [UUID]] = [:]
        for signal in signals.values {
            guard signal.kind == .clientAudioOutput, let appKey = signal.group?.appKey else { continue }
            guard SessionMachineRules.isActual(signal, now: now, weights: weights) else { continue }
            let related = live.filter { session in
                SessionMachineRules.relates(
                    signal: signal,
                    sessionMeetingId: session.meetingId,
                    sessionState: session.state,
                    sessionProvider: session.event?.conference?.provider,
                    deadlines: session.event.map { SessionMachineRules.arm(for: $0, settings: settings) },
                    now: now
                )
            }
            if related.count >= 2 {
                found[appKey] = related.map(\.sessionId).sorted(by: SessionMachineOrder.ascending)
            }
        }
        return found
    }

    /// Спрос `.whichMeeting` — один на спор, а не по одному на кандидата. Снимается сам,
    /// когда спор разошёлся: цель перестала быть актуальной либо отнеслась к одной сессии.
    func updateDisputePrompts(now: Date) {
        for (appKey, promptId) in Array(disputes) where contested[appKey] == nil {
            withdrawPrompt(promptId)
            disputes[appKey] = nil
        }
        for (appKey, candidates) in contested.sorted(by: { $0.key < $1.key }) where disputes[appKey] == nil {
            guard let first = candidates.first else { continue }
            let prompt = SessionPrompt(
                promptId: UUID(),
                sessionId: first,
                kind: .whichMeeting(candidates: candidates),
                raisedAt: now,
                expiresAt: nil
            )
            disputes[appKey] = prompt.promptId
            raised[prompt.promptId] = (prompt: prompt, isWithdrawn: false)
            promptOrder.append(prompt.promptId)
            hub.publish(.promptRaised(prompt))
        }
    }

    func withdrawPrompt(_ promptId: UUID) {
        guard var stored = raised[promptId], !stored.isWithdrawn else { return }
        stored.isWithdrawn = true
        raised[promptId] = stored
        hub.publish(.promptWithdrawn(promptId: promptId))
    }
}
