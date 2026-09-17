//  Вход в запись, остановка и ad-hoc — контракт C-018 (MEE-276), §7 (строки 6, 8, 10, 16),
//  §7.1, §8.2, §8.4, §8.6 и §9.3 (инвариант 19).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ B задачи MEE-300.
//
//  ЧЕТЫРЕ ПОЛЯ `CaptureRequest` ВЗЯТЫ ПО КОНВЕНЦИИ, И ЭТО НАЗВАНО ЗДЕСЬ ЖЕ, А НЕ ТОЛЬКО В
//  ОТЧЁТЕ. `CaptureRequest` (C-004 §2) несёт семь полей. Три из них C-018 называет прямо:
//  `recordingId` (§1.3), `meetingId` (§1.3) и `group` (§5.3). Источника остальных четырёх —
//  `directory`, `input`, `systemFormat`, `micFormat` — не называет ни C-018, ни `AppSettings`
//  (C-016 §2), ни один объявленный порт: `FileLayout` (C-010 §1) в дереве не объявлен вовсе,
//  а форматов и выбора устройства ввода нет ни в одной настройке. §«Данные на границе»
//  требует при этом, чтобы каталог машина ПОЛУЧАЛА от хранилища и передавала не разбирая, —
//  то есть требование стоит, а средство отсутствует. Взято по §3 правил проекта: все четыре
//  приходят машине при сборке, ни одного своего значения она не заводит и каталога не
//  строит. Условие снятия — объявление `FileLayout` и владелец у форматов.

import Foundation

extension SessionMachine {

    // MARK: - §7, строки 6, 8 и 16: вход в запись

    /// Вход в `recording`: `recordingId`, захват, токен питания, переход.
    ///
    /// ПОРЯДОК ЗДЕСЬ НЕСУЩИЙ. Захват зовётся ПРЕЖДЕ, чем берётся токен: `start` вправе
    /// отказать, и токен, взятый до отказа, остался бы висеть — инвариант 19 требует
    /// «взятых и отпущенных поровну», а не «поровну, когда всё удалось». Переход идёт
    /// последним, потому что инвариант 18 кладёт `setStatus` прежде публикации снимка, а
    /// публиковать `recording` прежде, чем захват его подтвердил, значит обещать наружу
    /// запись, которой нет.
    @discardableResult
    func enterRecording(
        _ identifier: UUID,
        target: ProcessGroup,
        observedAt: Date,
        now: Date
    ) async throws -> UUID {
        guard var session = store[identifier] else {
            throw SessionError.noSuchSession(sessionId: identifier)
        }
        let recordingId = UUID()
        let request = CaptureRequest(
            recordingId: recordingId,
            meetingId: session.meetingId,
            directory: recordingDirectory(recordingId),
            group: target,
            input: captureInput,
            systemFormat: systemFormat,
            micFormat: micFormat
        )
        do {
            _ = try await capture.start(request)
        } catch let error as CaptureError {
            throw SessionError.capture(error)
        }
        let token = await power.beginActivity(reason: .recording, label: recordingId.uuidString)

        session.recordingId = recordingId
        session.target = target
        session.lastTargetObservedAt = observedAt
        session.powerToken = token
        store[identifier] = session
        do {
            try await transition(identifier, to: .recording, now: now)
        } catch {
            // Исход не записан — значит перехода не было (инвариант 18). Токен при этом
            // взят, и держать его нечему: состояние осталось прежним.
            token.end()
            store[identifier]?.powerToken = nil
            throw error
        }
        return recordingId
    }

    // MARK: - §7, строки 10 и 13: остановка

    /// Вход в `stopping` и вызов `stop()` захвата.
    ///
    /// `stop()` бросил — строка 13 (`stopping → failed`), и задача цепочки при этом не
    /// ставится ни одна (К41). Манифест, который `stop()` вернул, здесь не читается:
    /// строка 12 стоит на `CaptureEvent.stopped(manifest)`, а не на ответе метода, — два
    /// источника одного манифеста разошлись бы молча.
    func enterStopping(_ identifier: UUID, now: Date) async throws {
        try await transition(identifier, to: .stopping, now: now)
        do {
            _ = try await capture.stop()
        } catch {
            try await transition(identifier, to: .failed, now: now)
        }
    }

    // MARK: - §7.1: одна группа — одна запись

    /// Сессия, занявшая эту группу идущей записью, либо `nil`.
    ///
    /// Читаются ОБА состояния множества — `recording` и `stopping`: `stopping` держится до
    /// прихода манифеста, то есть ровно то окно, в которое второй созвон и начинается.
    /// Реализация, смотрящая только на `recording`, красна на К47 одним словом условия.
    func sessionHolding(appKey: String, excluding identifier: UUID?) -> UUID? {
        store.values
            .filter { $0.sessionId != identifier }
            .filter { $0.state == .recording || $0.state == .stopping }
            .filter { $0.target?.appKey == appKey }
            .map(\.sessionId)
            .sorted(by: SessionMachineOrder.ascending)
            .first
    }

    /// Три клаузы строк 6 и 8 для этой сессии в этот момент.
    func gate(for session: SessionMachineSession) -> SessionMachineRules.RecordingGate {
        guard let target = session.target else { return .closed }
        // AD-HOC В `recording` УВОДИТ ТОЛЬКО СТРОКА 16, И ЭТО НЕ ОГОВОРКА. §8.6 требует
        // ответа человека при `.auto` ТОЖЕ — «`.auto` есть согласие записывать
        // запланированное, а незапланированный созвон человек не планировал», — то есть
        // политика цель такой сессии не отдаёт ни при одном значении, и строки 6 и 8 у неё
        // не срабатывают. Заводит её ответ `.record` либо команда, и обе идут строкой 16.
        let allowed = session.origin == .scheduled && SessionMachineRules.policyAllowsRecording(
            policy: settings.recordingPolicy,
            recordAnswered: session.recordAnswered
        )
        return SessionMachineRules.RecordingGate(
            hasTarget: true,
            isTargetTaken: sessionHolding(appKey: target.appKey, excluding: session.sessionId) != nil,
            isAllowedByPolicy: allowed
        )
    }

    /// Актуальный сигнал звучащей цели с этим `appKey`, либо `nil`.
    func actualSignal(appKey: String, now: Date) -> MeetingSignal? {
        signals.values.first {
            $0.kind == .clientAudioOutput
                && $0.group?.appKey == appKey
                && SessionMachineRules.isActual($0, now: now, weights: weights)
        }
    }

    // MARK: - §8.6: ad-hoc созвон без события

    /// Актуальные звучащие цели, не отнесённые ни к одной живой сессии (§5.4, правило 4),
    /// по возрастанию `appKey` — порядок ответа не зависит от порядка обхода набора.
    ///
    /// - Parameter excludingOwned: снимать ли цели, которые уже держит живая сессия. Спрос
    ///   §8.6 их снимает — иначе он поднимался бы заново каждым `tick` на одну и ту же
    ///   группу. Команда `startRecording(meetingId: nil)` их НЕ снимает: она обязана дойти
    ///   до проверки §7.1 и ответить `alreadyRecording`, а не `nothingToRecord` (К48).
    func unattachedTargets(now: Date, excludingOwned: Bool) -> [MeetingSignal] {
        let known = Array(store.values)
        let live = known.filter { !$0.state.isTerminalSession }
        return signals.values
            .filter { $0.kind == .clientAudioOutput && $0.group != nil }
            .filter { SessionMachineRules.isActual($0, now: now, weights: weights) }
            .filter { signal in
                // ОТНЕСЕНИЕ ЧИТАЕТСЯ ПО ВСЕМ СЕССИЯМ, А НЕ ПО ЖИВЫМ, И ЭТО НЕСУЩЕЕ.
                // Правила 2 и 3 §5.4 стоят на ОКНЕ события, а не на состоянии сессии:
                // сигнал, попавший в окно встречи, отнесён к ней и тогда, когда её сессия
                // уже терминальна. Читая только живых, машина подняла бы спрос ad-hoc на
                // созвон встречи, которую человек только что пропустил командой `skip`, —
                // то есть переспросила бы уже принятое решение. **Цена названа:** новый,
                // настоящий ad-hoc того же клиента внутри чужого окна спроса не получит;
                // предел цены — `graceEndsAt` этой встречи, и он же предел окна.
                !known.contains { SessionMachineRules.relates(signal: signal, to: side(of: $0), now: now) }
            }
            .filter { signal in
                guard excludingOwned else { return true }
                return !live.contains {
                    $0.adHocAppKey == signal.group?.appKey || $0.target?.appKey == signal.group?.appKey
                }
            }
            .sorted { ($0.group?.appKey ?? "") < ($1.group?.appKey ?? "") }
    }

    /// Спрос ad-hoc: поднять новый, снять отработавший.
    ///
    /// **При `.manual` не поднимается вовсе, и сессия не заводится ни одна** — политика
    /// говорит «только по команде», и спрос был бы её нарушением (§8.6). При `.auto`
    /// спрашивается ТОЖЕ: `.auto` есть согласие записывать запланированное, а незапланированный
    /// созвон человек не планировал (К60).
    func updateAdHoc(now: Date) async {
        await withdrawStaleAdHoc(now: now)
        guard settings.recordingPolicy != .manual else { return }
        for signal in unattachedTargets(now: now, excludingOwned: true) {
            guard let group = signal.group else { continue }
            _ = openAdHocSession(target: group, now: now, raisePrompt: true)
        }
    }

    /// Спрос снимается САМ, когда цель перестала быть актуальной, и сессия уходит в
    /// `skipped`: спрашивать про созвон, который уже кончился, не о чем (§8.6, К61).
    ///
    /// РАСХОЖДЕНИЕ НАЗВАНО ЗДЕСЬ, А НЕ СПРЯТАНО: строки таблицы §7 у этого перехода нет.
    /// Строка 9 даёт `awaitingSignal → skipped` по команде, по ответу `.skip`, по отмене
    /// или удалению события и по `now ≥ graceEndsAt`; у ad-hoc-сессии события нет вовсе, и
    /// ни одна клауза на неё не наступает. Исполнено обещание §8.6 дословно, потому что без
    /// него К61 неисполним ничем, а сессия висела бы в `awaitingSignal` навсегда — ровно
    /// тот третий исход, который §8.3 объявляет несуществующим. Строка — архитектору C-018.
    private func withdrawStaleAdHoc(now: Date) async {
        for identifier in store.keys.sorted(by: SessionMachineOrder.ascending) {
            guard let session = store[identifier], session.origin == .adHoc else { continue }
            guard !session.state.isTerminalSession else { continue }
            guard session.state == .awaitingSignal else { continue }
            guard let appKey = session.adHocAppKey else { continue }
            guard actualSignal(appKey: appKey, now: now) == nil else { continue }
            if let promptId = session.promptId { withdrawPrompt(promptId) }
            try? await transition(identifier, to: .skipped, now: now)
        }
    }

    /// Новая сессия `origin == .adHoc` в состоянии `awaitingSignal`; при `raisePrompt` —
    /// и спрос при ней.
    ///
    /// `raisePrompt` разводит два входа §8.6, и разводит их сам контракт: спрос поднимает
    /// **цель**, а команда `startRecording(meetingId: nil)` заводит сессию **без спроса** —
    /// при `.manual` спрос не поднимается вовсе, и поднять его, чтобы тут же снять, значило
    /// бы опубликовать `promptRaised`, которого К60 не допускает ни одного.
    ///
    /// `expiresAt == nil` значит «держится, пока держится причина», а не «держится вечно»:
    /// снимает спрос `withdrawStaleAdHoc`, а не срок (К60, К61).
    private func openAdHocSession(target: ProcessGroup, now: Date, raisePrompt: Bool) -> UUID {
        let identifier = UUID()
        let prompt = SessionPrompt(
            promptId: UUID(),
            sessionId: identifier,
            kind: .recordThisMeeting,
            raisedAt: now,
            expiresAt: nil
        )
        let session = SessionMachineSession(
            sessionId: identifier,
            origin: .adHoc,
            meetingId: nil,
            state: .awaitingSignal,
            recordingId: nil,
            target: target,
            estimate: 0,
            enteredStateAt: now,
            updatedAt: now,
            event: nil,
            promptId: raisePrompt ? prompt.promptId : nil,
            recordAnswered: false,
            adHocAppKey: target.appKey,
            lastTargetObservedAt: target.observedAt,
            powerToken: nil
        )
        store[identifier] = session
        hub.publish(.session(snapshot(of: session)))
        guard raisePrompt else { return identifier }
        raised[prompt.promptId] = (prompt: prompt, isWithdrawn: false)
        promptOrder.append(prompt.promptId)
        hub.publish(.promptRaised(prompt))
        return identifier
    }

    /// `startRecording(meetingId: nil, now:)` — строка 16 по команде.
    ///
    /// Живая ad-hoc-сессия, поднятая спросом §8.6, переиспользуется: второй сессии на ту же
    /// цель заводить нечем и незачем. Её нет (политика `.manual` спроса не поднимает) —
    /// сессия заводится этой же командой.
    func startAdHocRecording(now: Date) async throws -> UUID {
        if let live = store.values.first(where: {
            $0.origin == .adHoc && !$0.state.isTerminalSession && $0.state != .recording
                && $0.state != .stopping && $0.target != nil
        }), let group = live.target, let signal = actualSignal(appKey: group.appKey, now: now) {
            if let occupant = sessionHolding(appKey: group.appKey, excluding: live.sessionId) {
                throw SessionError.alreadyRecording(sessionId: occupant)
            }
            if let promptId = live.promptId { withdrawPrompt(promptId) }
            return try await enterRecording(
                live.sessionId, target: group, observedAt: signal.observedAt, now: now
            )
        }
        guard let signal = unattachedTargets(now: now, excludingOwned: false).first,
              let group = signal.group else {
            throw SessionError.nothingToRecord
        }
        if let occupant = sessionHolding(appKey: group.appKey, excluding: nil) {
            throw SessionError.alreadyRecording(sessionId: occupant)
        }
        let opened = openAdHocSession(target: group, now: now, raisePrompt: false)
        return try await enterRecording(
            opened, target: group, observedAt: signal.observedAt, now: now
        )
    }
}
