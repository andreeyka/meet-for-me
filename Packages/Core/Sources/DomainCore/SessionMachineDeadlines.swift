//  Фаза сроков одного `tick(now:)` и спросы — контракт C-018 (MEE-276), §7 (строки,
//  наступающие по сроку и по пришедшему входу), §8.2 и §5.4.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТИ A (MEE-298) и B (MEE-300). Файл отделён от `SessionMachineTick.swift` по одному
//  доводу, и он механический: часть B довела тот файл до 392 строк при пределе линта в
//  400 (`file_length`), то есть до восьми строк запаса, а фазу сроков и спросы можно
//  вынести целиком — наружу они не видны ни одним символом. Путями машины остаются
//  `Sources/DomainCore/SessionMachine*.swift` — признак не тронут (условие `Т` плана
//  MEE-288 §2).
//
//  НАЗВАНО, А НЕ УМОЛЧАНО: `type_body_length` здесь ни при чём — линт 0.65.1 меряет тела
//  типов, а не расширений, и прогон 151 это подтвердил: при теле расширения в 283 строки
//  он нашёл ровно одно нарушение, и это была длинная строка теста.

import Foundation

extension SessionMachine {

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
                let input = SessionMachineRules.DeadlineInput(
                    state: session.state,
                    deadlines: deadlines,
                    eventGone: isGone(session),
                    gate: gate(for: session),
                    silenceStopsAt: silenceDeadline(of: session)
                )
                guard let row = SessionMachineRules.deadlineRow(input, now: now) else {
                    // Строк, наступающих по сроку, не подошло ни одной: дальше в порядке
                    // таблицы идут строки 11—15, наступающие по пришедшему входу.
                    let changed = (try? await applyArrivedRows(to: session, now: now)) ?? false
                    if changed { continue }
                    break
                }
                do {
                    try await apply(row, to: session, now: now)
                } catch {
                    // Исход не записан — значит перехода не было (инвариант 18). Срок
                    // наступит на следующем `tick`: терять решение молча дороже, чем ждать.
                    break
                }
            }
        }
    }

    /// Строка, подошедшая по сроку, исполняется своим ходом: строки 6 и 8 зовут захват и
    /// берут токен питания, строка 10 зовёт `stop()`, прочие — один переход.
    private func apply(
        _ row: SessionMachineRules.DeadlineRow,
        to session: SessionMachineSession,
        now: Date
    ) async throws {
        switch row {
        case .row6ArmedToRecording, .row8AwaitingSignalToRecording:
            guard let target = session.target else { return }
            let observedAt = session.lastTargetObservedAt ?? target.observedAt
            try await enterRecording(
                session.sessionId, target: target, observedAt: observedAt, now: now
            )
        case .row10RecordingToStopping:
            try await enterStopping(session.sessionId, now: now)
        case .row2ScheduledToArmed, .row3ScheduledToSkipped, .row4ArmedToSkipped,
             .row5ArmedToScheduled, .row7ArmedToAwaitingSignal, .row9AwaitingSignalToSkipped:
            try await transition(session.sessionId, to: row.target, now: now)
        }
    }

    /// Момент §8.4 для этой сессии; `nil` — цели не было ни разу, и отсчитывать не от чего.
    private func silenceDeadline(of session: SessionMachineSession) -> Date? {
        session.lastTargetObservedAt.map {
            SessionMachineRules.silenceStopsAt(
                lastTargetObservedAt: $0, settings: settings, weights: weights
            )
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
            // Состояния записи и обработки спроса не получают: спрос §8.2 существует затем,
            // чтобы разрешить строки 6 и 8, а они читаются только из `armed` и
            // `awaitingSignal`. Спросить «записать?» у сессии, которая уже пишет, — шум.
            guard session.state == .armed || session.state == .awaitingSignal
                || session.state == .scheduled else { continue }
            guard session.promptId == nil, !session.recordAnswered else {
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
                    to: SessionMachineRules.SessionSide(
                        meetingId: session.meetingId,
                        state: session.state,
                        provider: session.event?.conference?.provider,
                        deadlines: session.event.map { SessionMachineRules.arm(for: $0, settings: settings) }
                    ),
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
