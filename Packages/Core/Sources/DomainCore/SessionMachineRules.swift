//  Правила машины сессий чистыми функциями — контракт C-018 (MEE-276): §5.2, §5.3, §5.4,
//  §6, §7 (строки до входа в запись), §9.1.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ A задачи MEE-298. Здесь нет ни состояния, ни портов, ни `Date()`: всякой функции
//  «сейчас» приходит параметром (§4). Разведение сделано затем, чтобы правило проверялось
//  отдельно от хода машины, и затем же, чтобы `plan(now:)` части C строил `ScheduledArm`
//  ТОЙ ЖЕ функцией, а не второй, разошедшейся с этой на первой же правке настроек.
//
//  ЧЕГО ЗДЕСЬ НЕТ И ПОЧЕМУ. Строк 6, 8 и 10—16 таблицы §7 нет ни одной: вход в запись,
//  остановка и обработка — часть B задачи, и их отсутствие есть предмет части B, а не долг
//  этой. Восстановительного заведения §10 нет вовсе — часть C. Ни одна функция этого файла
//  не заводит состояний `recording`, `stopping` и `processing` ни одним ходом.
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
        let state: MeetingStatus
        let provider: String?
        let deadlines: ScheduledArm?
    }

    /// Относится ли сигнал к сессии в момент `now` — по ПЕРВОМУ подошедшему правилу.
    ///
    /// Порядок правил 1—4 существен и проверяется К23: реализация, читающая их в порядке
    /// «сперва по провайдеру», отнесёт календарный сигнал к чужой сессии с открытым окном.
    static func relates(signal: MeetingSignal, to side: SessionSide, now: Date) -> Bool {
        let sessionMeetingId = side.meetingId
        let sessionState = side.state
        let sessionProvider = side.provider
        let deadlines = side.deadlines

        // Правило 1.
        if signal.kind == .calendarWindow {
            guard let signalMeeting = signal.meetingId, let sessionMeeting = sessionMeetingId else {
                return false
            }
            return signalMeeting == sessionMeeting
        }

        let inWindow = deadlines.map { $0.armAt <= now && now <= $0.graceEndsAt } ?? false
        let capturing = sessionState == .recording || sessionState == .stopping

        // Правило 2.
        if let provider = signal.provider {
            guard let sessionProvider, sessionProvider == provider else { return false }  // правило 4
            return inWindow || capturing
        }

        // Правило 3.
        return inWindow || capturing
    }

    // MARK: - §5.3: звучащая цель

    /// Звучащая цель среди уже отнесённых к сессии и актуальных сигналов.
    ///
    /// Правило тотально и детерминировано: третья ступень различает любые два сигнала,
    /// потому что пара для сигнала с группой есть её `appKey`, а двух актуальных сигналов
    /// одной пары по инварианту 25 C-009 не бывает. Ответ поэтому не зависит ни от порядка
    /// подачи, ни от порядка обхода набора (К21).
    static func soundingTarget(among signals: [MeetingSignal], sessionProvider: String?) -> ProcessGroup? {
        let candidates = signals.filter { $0.kind == .clientAudioOutput && $0.group != nil }
        guard !candidates.isEmpty else { return nil }

        // Ступень 1: сигналы провайдера события сильнее прочих — но только если они есть.
        var strongest = candidates
        if let sessionProvider {
            let matching = candidates.filter { $0.provider == sessionProvider }
            if !matching.isEmpty { strongest = matching }
        }

        // Ступени 2 и 3.
        let best = strongest.min { lhs, rhs in
            if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
            return (lhs.group?.appKey ?? "") < (rhs.group?.appKey ?? "")
        }
        return best?.group
    }

    // MARK: - §6: оценка

    /// `estimate = 1 − Π (1 − weight_i)` по отнесённым и актуальным сигналам, включая
    /// собственный календарный. Пустое произведение равно единице, и оценка тогда ноль.
    static func estimate(over signals: [MeetingSignal]) -> Double {
        1 - signals.reduce(1.0) { $0 * (1 - $1.weight) }
    }

    // MARK: - §7: строки таблицы, наступающие по сроку

    /// Строка таблицы §7, срабатывающая в фазе сроков. Строк здесь ДЕВЯТЬ ИЗ ВОСЕМНАДЦАТИ —
    /// те, что до входа в запись, — и три из девяти (1, 1а, 1б) суть заведение, а не переход
    /// живой сессии, и живут в `openingState`.
    enum DeadlineRow: Equatable {
        case row2ScheduledToArmed
        case row3ScheduledToSkipped
        case row4ArmedToSkipped
        case row5ArmedToScheduled
        case row7ArmedToAwaitingSignal
        case row9AwaitingSignalToSkipped

        var target: MeetingStatus {
            switch self {
            case .row2ScheduledToArmed:
                return .armed
            case .row3ScheduledToSkipped, .row4ArmedToSkipped, .row9AwaitingSignalToSkipped:
                return .skipped
            case .row5ArmedToScheduled:
                return .scheduled
            case .row7ArmedToAwaitingSignal:
                return .awaitingSignal
            }
        }
    }

    /// Первая подошедшая строка в ПОРЯДКЕ ТАБЛИЦЫ, либо `nil` — ни одна не подошла.
    ///
    /// - Parameters:
    ///   - eventGone: событие отменено (`isCancelled`) либо удалено — клауза строк 3, 4 и 9.
    ///   - hasSoundingTarget: есть ли у сессии звучащая цель — клауза строки 9.
    ///
    /// Команда `skip` и ответ `.skip` здесь не стоят намеренно: они исполняются В МОМЕНТ
    /// ВЫЗОВА (§«Поведение»), а не в фазе сроков, и красит это К58.
    static func deadlineRow(
        state: MeetingStatus,
        deadlines: ScheduledArm?,
        eventGone: Bool,
        hasSoundingTarget: Bool,
        now: Date
    ) -> DeadlineRow? {
        switch state {
        case .scheduled:
            return fromScheduled(deadlines: deadlines, eventGone: eventGone, now: now)
        case .armed:
            return fromArmed(deadlines: deadlines, eventGone: eventGone, now: now)
        case .awaitingSignal:
            return fromAwaitingSignal(
                deadlines: deadlines, eventGone: eventGone, hasSoundingTarget: hasSoundingTarget, now: now
            )
        case .recording, .stopping, .processing, .ready, .failed, .skipped:
            // Терминальные — исходящих переходов нет ни одного (инвариант 3).
            // Состояния записи и обработки эта часть не заводит ни одним входом.
            return nil
        }
    }

    /// Строки 2 и 3 в порядке таблицы.
    private static func fromScheduled(deadlines: ScheduledArm?, eventGone: Bool, now: Date) -> DeadlineRow? {
        if let deadlines, deadlines.armAt <= now, now <= deadlines.graceEndsAt {
            return .row2ScheduledToArmed
        }
        if eventGone { return .row3ScheduledToSkipped }
        if let deadlines, now > deadlines.graceEndsAt { return .row3ScheduledToSkipped }
        return nil
    }

    /// Строки 4, 5 и 7 в порядке таблицы. Строки 6 (`armed → recording`) здесь нет — часть B.
    private static func fromArmed(deadlines: ScheduledArm?, eventGone: Bool, now: Date) -> DeadlineRow? {
        if eventGone { return .row4ArmedToSkipped }
        if let deadlines, now < deadlines.armAt { return .row5ArmedToScheduled }
        if let deadlines, now >= deadlines.startsAt { return .row7ArmedToAwaitingSignal }
        return nil
    }

    /// Строка 9. Строки 8 (`awaitingSignal → recording`) здесь нет — часть B.
    private static func fromAwaitingSignal(
        deadlines: ScheduledArm?,
        eventGone: Bool,
        hasSoundingTarget: Bool,
        now: Date
    ) -> DeadlineRow? {
        if eventGone { return .row9AwaitingSignalToSkipped }
        if let deadlines, now >= deadlines.graceEndsAt, !hasSoundingTarget {
            return .row9AwaitingSignalToSkipped
        }
        return nil
    }
}
