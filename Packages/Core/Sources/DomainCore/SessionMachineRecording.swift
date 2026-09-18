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
        // Поводов у третьей клаузы два, и второй заведён изданием v7: политика ЛИБО
        // команда. «Команда сильнее политики» (§«Поведение»), и с момента её вызова клауза
        // истинна при любом `recordingPolicy`, включая `.manual` (§8.2; К52, К34, К36).
        let allowed = session.origin == .scheduled && (
            session.commandGaveTarget || SessionMachineRules.policyAllowsRecording(
                policy: settings.recordingPolicy,
                recordAnswered: session.recordAnswered
            )
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

    /// Актуальные звучащие цели, которые §8.6 считает ВХОДОМ ad-hoc: не отнесённые ни к
    /// одной сессии правилами §5.4 (правило 4), по возрастанию `appKey` — порядок ответа не
    /// зависит от порядка обхода набора.
    ///
    /// ОТНЕСЕНИЕ ЧИТАЕТСЯ ПО ВСЕМ СЕССИЯМ, А НЕ ПО ЖИВЫМ, И ЭТО НЕСУЩЕЕ. Правила 2 и 3
    /// §5.4 стоят на ОКНЕ события, а не на состоянии сессии: сигнал, попавший в окно
    /// встречи, отнесён к ней и тогда, когда её сессия уже терминальна. Читая только живых,
    /// машина подняла бы спрос ad-hoc на созвон встречи, которую человек только что
    /// пропустил командой `skip`, — то есть переспросила бы уже принятое решение. **Цена
    /// названа:** новый, настоящий ad-hoc того же клиента внутри чужого окна спроса не
    /// получит; предел цены — `graceEndsAt` этой встречи, и он же предел окна.
    ///
    /// ОТДЕЛЬНОЙ КЛАУЗЫ «ЦЕЛЬ УЖЕ ДЕРЖИТ ЖИВАЯ СЕССИЯ» ЗДЕСЬ БОЛЬШЕ НЕТ, И ЭТО СЛЕДСТВИЕ
    /// ПРАВИЛА `1а`. Часть B снимала такие цели своим фильтром, потому что §5.4 не относил
    /// сигнал к уже заведённой ad-hoc-сессии ни одним правилом и тот оставался «не
    /// отнесённым» вечно. Правило `1а` относит его к ней самой, а сессию события в
    /// `{recording, stopping}` покрывают правила 2 и 3 клаузой состояния, — то есть прежний
    /// фильтр стал вторым ответом на тот же вопрос, и снят он ровно поэтому.
    func unattachedTargets(now: Date) -> [MeetingSignal] {
        let known = Array(store.values)
        return soundingSignals(now: now)
            .filter { signal in
                !known.contains { SessionMachineRules.relates(signal: signal, to: side(of: $0), now: now) }
            }
    }

    /// Актуальные сигналы, годные в звучащую цель по §5.3, по возрастанию `appKey`.
    func soundingSignals(now: Date) -> [MeetingSignal] {
        signals.values
            .filter { $0.kind == .clientAudioOutput && $0.group != nil }
            .filter { SessionMachineRules.isActual($0, now: now, weights: weights) }
            .sorted { ($0.group?.appKey ?? "") < ($1.group?.appKey ?? "") }
    }

    /// Спрос ad-hoc: поднять новый, снять отработавший.
    ///
    /// **При `.manual` не поднимается вовсе, и сессия не заводится ни одна** — политика
    /// говорит «только по команде», и спрос был бы её нарушением (§8.6). При `.auto`
    /// спрашивается ТОЖЕ: `.auto` есть согласие записывать запланированное, а незапланированный
    /// созвон человек не планировал (К60).
    func updateAdHoc(now: Date) {
        guard settings.recordingPolicy != .manual else { return }
        for signal in unattachedTargets(now: now) {
            guard let group = signal.group else { continue }
            _ = openAdHocSession(target: group, now: now, raisePrompt: true)
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
    /// спрос снимается вместе с уходом сессии в `skipped` строкой 9 по четвёртой
    /// бессроковой клаузе — «цель перестала быть актуальной» (§8.6; К60, К61), — а не
    /// сроком, которого у него нет.
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
            commandGaveTarget: false,
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
    /// ПРИ ЛЮБОЙ ПОЛИТИКЕ, ВКЛЮЧАЯ `.auto` И `.ask`, И БЕЗ ЕДИНОГО СПРОСА. У строки 16
    /// клаузы политики нет ни одной (§7, издание v7; §8.6, ветвь вторая): команда есть то
    /// самое решение человека, ради которого спрос и существует. Строку 1в она при этом не
    /// отменяет и с ней не спорит — разводит их МОМЕНТ ЧТЕНИЯ: 1в читается в `tick` и
    /// только в нём, 16 — в момент вызова и только в него. Команда, поданная до первого
    /// `tick` по этому сигналу, побеждает строку 1в, хотя та стоит в таблице раньше:
    /// порядок таблицы решает внутри ОДНОГО момента чтения (К44, К95 вектор (б′), К45).
    ///
    /// ЖИВАЯ AD-HOC-СЕССИЯ ПЕРЕИСПОЛЬЗУЕТСЯ, И УХОДИТ ОНА СТРОКОЙ 8, А НЕ 16. Условие
    /// заведения §8.6 при ней ложно — «живой ad-hoc-сессии с этим `appKey` нет» неверно, —
    /// и §7 говорит исход дословно: «сессия уходит в `recording` строкой 8 — политика
    /// отдаёт ей цель командой ровно так же, как ответом `.record`». Второй сессии не
    /// заводится ни одной (К44, вектор (б); К96).
    func startAdHocRecording(now: Date) async throws -> UUID {
        if let live = reusableAdHocSession(), let group = live.target,
           let signal = actualSignal(appKey: group.appKey, now: now) {
            if let occupant = sessionHolding(appKey: group.appKey, excluding: live.sessionId) {
                throw SessionError.alreadyRecording(sessionId: occupant)
            }
            if let promptId = live.promptId { withdrawPrompt(promptId) }
            // Строка 8: политика отдала цель командой, и переход идёт строкой таблицы.
            return try await enterRecording(
                live.sessionId, target: group, observedAt: signal.observedAt, now: now
            )
        }

        // §7.1 ЧИТАЕТСЯ ПРЕЖДЕ, ЧЕМ КОМАНДА ОТВЕТИТ «ЗАПИСЫВАТЬ НЕЧЕГО», И ПОРЯДОК ЗДЕСЬ
        // НЕСУЩИЙ. Цель, занятая идущей записью, отнесена к её держателю — правилом `1а`,
        // если держатель ad-hoc, правилами 2 и 3, если это сессия события в
        // `{recording, stopping}`, — то есть входом §8.6 она не является ни в одном из двух
        // случаев. Ответив на этом `nothingToRecord`, команда сказала бы человеку «созвона
        // нет», когда созвон есть и пишется; §7.1 требует назвать ЗАНИМАЮЩУЮ сессию, и
        // ровно это подаёт К48 веткой «ad-hoc».
        let free = unattachedTargets(now: now)
            .first { sessionHolding(appKey: $0.group?.appKey ?? "", excluding: nil) == nil }
        guard let signal = free, let group = signal.group else {
            let taken = soundingSignals(now: now).lazy
                .compactMap { sessionHolding(appKey: $0.group?.appKey ?? "", excluding: nil) }
                .first
            if let taken { throw SessionError.alreadyRecording(sessionId: taken) }
            throw SessionError.nothingToRecord
        }
        let opened = openAdHocSession(target: group, now: now, raisePrompt: false)
        return try await enterRecording(
            opened, target: group, observedAt: signal.observedAt, now: now
        )
    }

    /// Живая ad-hoc-сессия, которую команда уводит в запись строкой 8, либо `nil`.
    ///
    /// Состояния `recording` и `stopping` исключены намеренно: такая сессия уже пишет, и
    /// `recordingId` у неё назначен и не меняется (инвариант 5). По возрастанию
    /// `sessionId` — ответ не зависит от порядка обхода набора.
    private func reusableAdHocSession() -> SessionMachineSession? {
        store.values
            .filter { $0.origin == .adHoc && !$0.state.isTerminalSession }
            .filter { $0.state != .recording && $0.state != .stopping }
            .filter { $0.target != nil }
            .sorted { SessionMachineOrder.ascending($0.sessionId, $1.sessionId) }
            .first
    }
}
