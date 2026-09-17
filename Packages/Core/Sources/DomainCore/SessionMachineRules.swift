//  Правила машины сессий чистыми функциями — контракт C-018 (MEE-276): §5.2, §5.3, §5.4,
//  §6, §7 (строки, наступающие по сроку), §7.1, §8.2, §8.4, §9.1.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТИ A (MEE-298) и B (MEE-300). Здесь нет ни состояния, ни портов, ни `Date()`: всякой
//  функции «сейчас» приходит параметром (§4). Разведение сделано затем, чтобы правило
//  проверялось отдельно от хода машины, и затем же, чтобы `plan(now:)` части C строил
//  `ScheduledArm` ТОЙ ЖЕ функцией, а не второй, разошедшейся с этой на первой же правке
//  настроек.
//
//  ЧЕГО ЗДЕСЬ НЕТ И ПОЧЕМУ. Строк 11—16 таблицы §7 нет ни одной, и это не пропуск: они
//  наступают ПО ПРИХОДУ НАЗВАННОГО ВХОДА (`CaptureEvent`, `JobEvent`, команда, ответ на
//  спрос), а не по сроку, и фазе сроков не принадлежат — §«Поведение» разводит эти два
//  случая прямо. Восстановительного заведения §10 нет вовсе — часть C.
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

    // MARK: - §7: строки таблицы, наступающие по сроку

    /// Строка таблицы §7, срабатывающая в фазе сроков. Строк здесь ДВЕНАДЦАТЬ ИЗ
    /// ВОСЕМНАДЦАТИ — три заводящие (1, 1а, 1б) живут в `openingState`, а строки 11—16
    /// наступают по приходу названного входа, а не по сроку.
    enum DeadlineRow: Equatable {
        case row2ScheduledToArmed
        case row3ScheduledToSkipped
        case row4ArmedToSkipped
        case row5ArmedToScheduled
        case row6ArmedToRecording
        case row7ArmedToAwaitingSignal
        case row8AwaitingSignalToRecording
        case row9AwaitingSignalToSkipped
        case row10RecordingToStopping

        var target: MeetingStatus {
            switch self {
            case .row2ScheduledToArmed:
                return .armed
            case .row3ScheduledToSkipped, .row4ArmedToSkipped, .row9AwaitingSignalToSkipped:
                return .skipped
            case .row5ArmedToScheduled:
                return .scheduled
            case .row6ArmedToRecording, .row8AwaitingSignalToRecording:
                return .recording
            case .row7ArmedToAwaitingSignal:
                return .awaitingSignal
            case .row10RecordingToStopping:
                return .stopping
            }
        }
    }

    /// То, что фаза сроков читает у сессии. Отдельным значением, а не пятью параметрами, по
    /// тому же доводу, каким заведён `SessionSide`: шесть подряд линт считает нарушением, а
    /// читатель — перечнем без предмета.
    struct DeadlineInput {

        let state: MeetingStatus
        let deadlines: ScheduledArm?

        /// Событие отменено (`isCancelled`) либо удалено — клауза строк 3, 4 и 9.
        let eventGone: Bool

        /// Три клаузы строк 6 и 8 разом (§5.3, §7.1, §8.2) — и отрицание этих же трёх в
        /// клаузе строки 9.
        let gate: RecordingGate

        /// Момент §8.4 — `observedAt` последней актуальной цели плюс `signalTtlSeconds`
        /// плюс `silenceStopSeconds`; `nil` — цели не было ни разу.
        let silenceStopsAt: Date?
    }

    /// Первая подошедшая строка в ПОРЯДКЕ ТАБЛИЦЫ, либо `nil` — ни одна не подошла.
    ///
    /// Команда `skip`, команды `startRecording`/`stopRecording` и ответ на спрос здесь не
    /// стоят намеренно: они исполняются В МОМЕНТ ВЫЗОВА (§«Поведение»), а не в фазе сроков,
    /// и красит это К58.
    static func deadlineRow(_ input: DeadlineInput, now: Date) -> DeadlineRow? {
        let deadlines = input.deadlines
        let eventGone = input.eventGone
        let gate = input.gate
        switch input.state {
        case .scheduled:
            return fromScheduled(deadlines: deadlines, eventGone: eventGone, now: now)
        case .armed:
            return fromArmed(deadlines: deadlines, eventGone: eventGone, gate: gate, now: now)
        case .awaitingSignal:
            return fromAwaitingSignal(
                deadlines: deadlines, eventGone: eventGone, gate: gate, now: now
            )
        case .recording:
            return fromRecording(gate: gate, silenceStopsAt: input.silenceStopsAt, now: now)
        case .stopping, .processing:
            // Исходящие строки этих состояний — 11—15 — наступают по приходу
            // `CaptureEvent` и `JobEvent`, а не по сроку: фаза сроков их не читает.
            return nil
        case .ready, .failed, .skipped:
            // Терминальные — исходящих переходов нет ни одного (инвариант 3).
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

    /// Строки 4, 5, 6 и 7 в порядке таблицы.
    ///
    /// Строка 6 стоит ПРЕЖДЕ строки 7, и порядок здесь несущий: при звучащей цели и
    /// `now ≥ e.start` истинны обе, и побеждает строка с меньшим номером — К45 (ii) и К35.
    /// Реализация, читающая сроковые строки прежде сигнальных, уводит сессию в
    /// `awaitingSignal` и теряет начало созвона.
    private static func fromArmed(
        deadlines: ScheduledArm?,
        eventGone: Bool,
        gate: RecordingGate,
        now: Date
    ) -> DeadlineRow? {
        if eventGone { return .row4ArmedToSkipped }
        if let deadlines, now < deadlines.armAt { return .row5ArmedToScheduled }
        if gate.maySwitchToRecording { return .row6ArmedToRecording }   // ранний вход §8.1
        if let deadlines, now >= deadlines.startsAt { return .row7ArmedToAwaitingSignal }
        return nil
    }

    /// Строки 8 и 9 в порядке таблицы.
    ///
    /// КЛАУЗА СТРОКИ 9 ЧИТАЕТ ВСЕ ТРИ ПРИЧИНЫ, А НЕ ОДНУ, И ЭТО ПРАВКА ПОД C-018 v5.
    /// До v5 здесь стояло `!hasSoundingTarget`, то есть одна причина из трёх; клауза
    /// строки 9 в v5 называет их перечнем: «цели нет (§8.3), либо цель есть, но занята
    /// (§7.1) или не отдана политикой (§8.2)». Отрицание условия строки 8 даёт ровно эти
    /// три случая и ни одного четвёртого — спор §5.4 закрыт первым из них, потому что
    /// оспариваемая цель звучащей целью не является. Реализация со старой клаузой
    /// оставляла сессию при `.manual` и при `.ask` без ответа со звучащей целью висеть в
    /// `awaitingSignal` навсегда, при том что §8.2 и §8.3 обещают ей `skipped` дословно.
    ///
    /// Короткая форма «либо `now ≥ graceEndsAt`» здесь отвергнута контрактом вслух: в
    /// полной машине она даёт тот же ответ, потому что строка 8 стоит раньше, — но
    /// читается как отмена строки 8.
    private static func fromAwaitingSignal(
        deadlines: ScheduledArm?,
        eventGone: Bool,
        gate: RecordingGate,
        now: Date
    ) -> DeadlineRow? {
        if eventGone { return .row9AwaitingSignalToSkipped }
        if gate.maySwitchToRecording { return .row8AwaitingSignalToRecording }
        if let deadlines, now >= deadlines.graceEndsAt, !gate.maySwitchToRecording {
            return .row9AwaitingSignalToSkipped
        }
        return nil
    }

    /// Строка 10 в её сроковой половине — §8.4, правило 2.
    ///
    /// `e.end` здесь не стоит ни одной клаузой, и это требование §8.4 правила 1 дословно:
    /// конец окна события запись не останавливает (К38, К56). Команда `stopRecording` —
    /// вторая половина строки 10 — исполняется в момент вызова и сюда не приходит (К58).
    private static func fromRecording(
        gate: RecordingGate,
        silenceStopsAt: Date?,
        now: Date
    ) -> DeadlineRow? {
        guard !gate.hasTarget, let stopsAt = silenceStopsAt, now >= stopsAt else { return nil }
        return .row10RecordingToStopping
    }
}
