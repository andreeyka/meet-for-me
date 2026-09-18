//  Правила машины сессий чистыми функциями — контракт C-018 (MEE-276): §5.2, §5.3, §5.4,
//  §6, §9.1. Строки таблицы §7 живут в `SessionMachineTableRows.swift`, замок строк 6, 8 и
//  16 — в `SessionMachineEntryRules.swift`; разводит их предел линта, а не смысл.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТИ A (MEE-298), B (MEE-300) и C (MEE-307). Здесь нет ни состояния, ни портов, ни
//  `Date()`: всякой функции «сейчас» приходит параметром (§4). Разведение сделано затем,
//  чтобы правило проверялось отдельно от хода машины, и затем же, чтобы `plan(now:)` части
//  C строил `ScheduledArm` ТОЙ ЖЕ функцией, а не второй, разошедшейся с этой на первой же
//  правке настроек. Частью C это обещание исполнено дословно: `Scheduler.plan(now:)` зовёт
//  `arm(for:settings:)` ниже, и второго счёта сроков в дереве нет ни одного.
//
//  ЧЕГО ЗДЕСЬ НЕТ И ПОЧЕМУ. Восстановительного заведения §10 нет ни строкой: оно не есть
//  правило перехода — таблицей §7 оно не описывается вовсе (инвариант 2, названное
//  исключение), — и живёт в `SessionMachineRecovery.swift`.
//
//  ТЕРМИНОВ C-009 ЭТОТ ФАЙЛ НЕ ОПРЕДЕЛЯЕТ НИ ОДНОГО (§0 контракта, инвариант 6). Он их
//  ПРИМЕНЯЕТ: актуальность и пара «вид + источник» взяты у C-009 §1 дословно, а срок
//  приходит значением таблицы весов, прочитанным публичным членом `SignalWeights`, — своего
//  числа здесь нет ни одного.

import Foundation

/// Правила контракта C-018, приведённые к чистым функциям.
enum SessionMachineRules {

    // MARK: - §9.1 и §3.2: сроки сессии

    /// Сроки одного события. Считаются от `e.start` и от момента заведения не зависят
    /// ни на секунду (§9.1, второй пункт).
    ///
    /// Тип ответа — `ScheduledArm` контракта (§3.2), а не собственная пятёрка полей:
    /// поля те же самые, и второе их определение разошлось бы с первым молча.
    static func arm(for event: MeetingEvent, settings: AppSettings) -> ScheduledArm {
        ScheduledArm(
            meetingId: event.id,
            armAt: event.start.addingTimeInterval(-TimeInterval(settings.armLeadSeconds)),
            askAt: settings.recordingPolicy == .ask
                ? event.start.addingTimeInterval(-TimeInterval(settings.askLeadSeconds))
                : nil,
            startsAt: event.start,
            endsAt: event.end,
            graceEndsAt: event.start.addingTimeInterval(TimeInterval(settings.missingSignalGraceSeconds))
        )
    }

    // MARK: - §9.1: одно условие заведения на весь контракт

    /// Заводится ли сессия для этого события в момент `now`.
    ///
    /// Это ОДНО условие на весь контракт: строки 1, 1а и 1б §7 стоят на нём дословно и
    /// различаются только тем, в какое состояние сессия заводится (`openingState`).
    ///
    /// - Parameters:
    ///   - storedStatus: хранимый `MeetingStatus` встречи (C-010). `nil` — строки у встречи
    ///     нет вовсе, и терминального решения по ней не записано никем.
    ///   - hasLiveSession: есть ли у встречи нетерминальная сессия сейчас (инвариант 4).
    static func mayOpenSession(
        event: MeetingEvent,
        storedStatus: MeetingStatus?,
        hasLiveSession: Bool,
        settings: AppSettings,
        now: Date
    ) -> Bool {
        guard !event.isAllDay else { return false }
        guard !event.isCancelled else { return false }
        guard !hasLiveSession else { return false }
        if let storedStatus, storedStatus.isTerminalSession { return false }
        return now <= arm(for: event, settings: settings).graceEndsAt
    }

    /// Состояние заведения есть функция от `now`, а не всегда `scheduled` (§9.1).
    ///
    /// Строки читаются В ПОРЯДКЕ ТАБЛИЦЫ: 1, затем 1а, затем 1б. На неотрицательных сроках
    /// три условия суть разбиение отрезка и порядок между ними безразличен (§7, абзац о
    /// взаимном исключении); соотношений между настройками контракт не требует ни одного
    /// (§5.1), и на отрицательном `armLeadSeconds` порядок таблицы решает спор сам.
    static func openingState(event: MeetingEvent, settings: AppSettings, now: Date) -> MeetingStatus? {
        let deadlines = arm(for: event, settings: settings)
        if now < deadlines.armAt { return .scheduled }              // строка 1
        if now < deadlines.startsAt { return .armed }               // строка 1а
        if now <= deadlines.graceEndsAt { return .awaitingSignal }  // строка 1б
        return nil
    }

    // MARK: - C-009 §1: пара «вид + источник»

    /// Пара, по которой идёт слияние (C-009 §1). Источник определён тотально и без
    /// пересечений: у `calendarWindow` это `meetingId`, у сигнала с группой — `group.appKey`,
    /// у сигнала без группы — `pid`.
    struct SignalPair: Hashable {
        let kind: MeetingSignalKind
        let source: String
    }

    static func pair(of signal: MeetingSignal) -> SignalPair {
        let source: String
        switch signal.kind {
        case .calendarWindow:
            source = signal.meetingId.map(\.uuidString) ?? ""
        case .clientRunning, .clientAudioOutput, .microphoneInUse:
            if let group = signal.group {
                source = group.appKey
            } else if let pid = signal.pid {
                source = String(pid)
            } else {
                source = ""
            }
        }
        return SignalPair(kind: signal.kind, source: source)
    }

    /// Актуален ли сигнал в момент `now` (C-009 §1): «пока с его `observedAt` прошло НЕ
    /// БОЛЬШЕ `signalTtlSeconds` из таблицы весов». Число приходит значением таблицы;
    /// своего срока у машины нет ни одного.
    static func isActual(_ signal: MeetingSignal, now: Date, weights: SignalWeights) -> Bool {
        now.timeIntervalSince(signal.observedAt) <= TimeInterval(weights.signalTtlSeconds)
    }

    // MARK: - §5.2: собственный календарный сигнал

    /// Сигнал существует ТОГДА И ТОЛЬКО ТОГДА, когда `e.start ≤ now < e.end` (инвариант 8).
    /// Строится в момент пересчёта оценки и потребляется той же сессией, которая его
    /// построила: в поток `signals()` он не уходит и вторым потребителем не наблюдается.
    static func calendarSignal(
        for event: MeetingEvent,
        origin: SessionOrigin,
        weights: SignalWeights,
        now: Date
    ) -> MeetingSignal? {
        guard origin == .scheduled else { return nil }
        guard event.start <= now, now < event.end else { return nil }
        return MeetingSignal(
            kind: .calendarWindow,
            weight: weights.weight(for: .calendarWindow),
            pid: nil,
            bundleId: nil,
            group: nil,
            provider: nil,
            meetingId: event.id,
            observedAt: now
        )
    }

    // MARK: - §5.4: отнесение сигнала к сессии

    /// То, что правило §5.4 читает у сессии. Отдельным значением, а не шестью параметрами:
    /// шесть подряд линт считает нарушением, а читатель — перечнем без предмета.
    struct SessionSide {
        let meetingId: UUID?
        let origin: SessionOrigin
        let state: MeetingStatus
        let provider: String?
        let deadlines: ScheduledArm?

        /// `appKey` цели, НАЗНАЧЕННЫЙ ad-hoc-сессии при заведении (§8.6) — предмет правила
        /// `1а`. У `origin == .scheduled` всегда `nil`.
        let adHocAppKey: String?
    }

    /// Правило §5.4, отнёсшее сигнал к сессии; `nil` — правило 4, не отнесло ни одно.
    ///
    /// ОТВЕТОМ СЛУЖИТ НОМЕР ПРАВИЛА, А НЕ «ДА/НЕТ», И ЭТО НЕСУЩЕЕ. §5.4 издания v7 говорит
    /// о споре двумя предложениями, и они читают РАЗНОЕ: определение спора стоит на ЧИСЛЕ
    /// сессий, к которым сигнал отнесён «правилом 2 либо правилом 3, безразлично каким», а
    /// правило `1а` говорит, что ad-hoc-сессия в число сторон не входит. Ответ «да/нет»
    /// этих двух предложений различить не даёт ничем: он не помнит, каким правилом отнесён.
    enum Relation: Equatable {
        case rule1Calendar
        case rule1aAdHoc
        case rule2Provider
        case rule3NoProvider

        /// Является ли сессия СТОРОНОЙ спора по этому отнесению (§5.4, издание v7).
        ///
        /// Истинно ровно для правил 2 и 3. Отнесение правилом `1а` стороны не прибавляет —
        /// см. разбор в шапке `relation(signal:to:now:)`.
        var isDisputeParty: Bool {
            self == .rule2Provider || self == .rule3NoProvider
        }
    }

    /// Относится ли сигнал к сессии в момент `now` — по ПЕРВОМУ подошедшему правилу.
    static func relates(signal: MeetingSignal, to side: SessionSide, now: Date) -> Bool {
        relation(signal: signal, to: side, now: now) != nil
    }

    /// Правило §5.4, относящее сигнал к сессии, — по ПЕРВОМУ подошедшему.
    ///
    /// Порядок правил 1, `1а`, 2, 3, 4 существен и проверяется К23: реализация, читающая их
    /// в порядке «сперва по провайдеру», отнесёт календарный сигнал к чужой сессии с
    /// открытым окном, а сигнал ad-hoc-сессии — к сессии события, чьё окно открыто, минуя
    /// правило `1а`.
    ///
    /// ПРАВИЛО `1а` СТОИТ НА НАЗНАЧЕННОМ `appKey`, А НЕ НА `target`. §5.4 дословно: «`s.group?
    /// .appKey` равен `appKey` цели, НАЗНАЧЕННОМУ ПРИ ЗАВЕДЕНИИ». `target` есть цель
    /// актуальная (§5.3) и гаснет на всякий срок §8.4, пока запись жива, — по нему правило
    /// читалось бы иначе на том самом входе, который К96 (в) подаёт различающим.
    ///
    /// КЛАУЗА «`S` НЕ ТЕРМИНАЛЬНА» ЕСТЬ ЧАСТЬ ПРАВИЛА, А НЕ ОСНАСТКА: после терминального
    /// состояния признак ad-hoc-сессии освобождается, и по той же цели заводится новая
    /// (К96, вектор (б); К97).
    static func relation(signal: MeetingSignal, to side: SessionSide, now: Date) -> Relation? {
        // Правило 1.
        if signal.kind == .calendarWindow {
            guard let signalMeeting = signal.meetingId, let sessionMeeting = side.meetingId else {
                return nil
            }
            return signalMeeting == sessionMeeting ? .rule1Calendar : nil
        }

        // Правило 1а (издание v6).
        if side.origin == .adHoc, !side.state.isTerminalSession,
           let assigned = side.adHocAppKey, signal.group?.appKey == assigned {
            return .rule1aAdHoc
        }

        let inWindow = side.deadlines.map { $0.armAt <= now && now <= $0.graceEndsAt } ?? false
        let capturing = side.state == .recording || side.state == .stopping

        // Правило 2.
        if let provider = signal.provider {
            guard let sessionProvider = side.provider, sessionProvider == provider else {
                return nil   // правило 4
            }
            return (inWindow || capturing) ? .rule2Provider : nil
        }

        // Правило 3.
        return (inWindow || capturing) ? .rule3NoProvider : nil
    }

    // MARK: - §5.3: звучащая цель

    /// Звучащая цель среди уже отнесённых к сессии и актуальных сигналов.
    ///
    /// Правило тотально и детерминировано: третья ступень различает любые два сигнала,
    /// потому что пара для сигнала с группой есть её `appKey`, а двух актуальных сигналов
    /// одной пары по инварианту 25 C-009 не бывает. Ответ поэтому не зависит ни от порядка
    /// подачи, ни от порядка обхода набора (К21).
    static func soundingTarget(among signals: [MeetingSignal], sessionProvider: String?) -> ProcessGroup? {
        soundingTargetSignal(among: signals, sessionProvider: sessionProvider)?.group
    }

    /// Тот же выбор, но ответом служит САМ СИГНАЛ, а не его группа.
    ///
    /// Второй функции здесь нет — есть одна, и `soundingTarget` отдаёт её `group`: §8.4
    /// отсчитывает срок остановки от `observedAt` последней актуальной цели, а `ProcessGroup`
    /// несёт свой `observedAt`, который сигналу равен не по правилу, а по совпадению у
    /// сегодняшнего производителя. Два определения «момента цели» разошлись бы молча.
    static func soundingTargetSignal(
        among signals: [MeetingSignal],
        sessionProvider: String?
    ) -> MeetingSignal? {
        let candidates = signals.filter { $0.kind == .clientAudioOutput && $0.group != nil }
        guard !candidates.isEmpty else { return nil }

        // Ступень 1: сигналы провайдера события сильнее прочих — но только если они есть.
        var strongest = candidates
        if let sessionProvider {
            let matching = candidates.filter { $0.provider == sessionProvider }
            if !matching.isEmpty { strongest = matching }
        }

        // Ступени 2 и 3.
        return strongest.min { lhs, rhs in
            if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
            return (lhs.group?.appKey ?? "") < (rhs.group?.appKey ?? "")
        }
    }

    // MARK: - §6: оценка

    /// `estimate = 1 − Π (1 − weight_i)` по отнесённым и актуальным сигналам, включая
    /// собственный календарный. Пустое произведение равно единице, и оценка тогда ноль.
    static func estimate(over signals: [MeetingSignal]) -> Double {
        1 - signals.reduce(1.0) { $0 * (1 - $1.weight) }
    }
}
