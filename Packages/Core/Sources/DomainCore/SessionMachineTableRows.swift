//  Строки таблицы §7, читаемые фазой сроков и командой, — контракт C-018 (MEE-276): §7,
//  §7.1, §8.2, §8.3 и §8.4.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ C задачи MEE-307. Файл отделён от `SessionMachineRules.swift` по одному доводу, и
//  он механический: правка правила `1а` §5.4 и четвёртой бессроковой клаузы строки 9 довела
//  тот файл до 474 строк при пределе линта в 400 (`file_length`), а таблицу §7 можно
//  вынести целиком — наружу она не видна ни одним символом. Правила остаются членами того
//  же `SessionMachineRules`: второго места для правил машины не заводится (К4, К19).
//  Путями машины остаются `Sources/DomainCore/SessionMachine*.swift` — признак не тронут
//  (условие `Т` плана MEE-288 §2).
//
//  ЗДЕСЬ НЕТ НИ СОСТОЯНИЯ, НИ ПОРТОВ, НИ `Date()`: «сейчас» приходит параметром (§4).

import Foundation

extension SessionMachineRules {

    // MARK: - §7: строки таблицы, наступающие по сроку

    /// Строка таблицы §7, срабатывающая в фазе сроков. Строк здесь ДЕВЯТЬ ИЗ ДЕВЯТНАДЦАТИ —
    /// четыре заводящие (1, 1а, 1б, 1в) живут в `openingState` и в §8.6, а строки 11—16
    /// наступают по приходу названного входа, а не по сроку.
    ///
    /// ОБА ЧИСЛА ПРАВЛЕНЫ ЧАСТЬЮ C, И ОБА БЫЛИ ЛОЖНЫ. «Восемнадцать» — счёт издания v5;
    /// строку 1в завело v6, и §7 издания v7 правит своё же число на **девятнадцать**
    /// (1, 1а, 1б, 1в, 2…16). «Двенадцать» не было верно ни при одном издании: перечисление
    /// ниже несёт девять случаев — строки 2…10, — и прогон по нему это показывает счётом.
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

        /// Четвёртая бессроковая клауза строки 9: «у ad-hoc-сессии — её цель перестала быть
        /// актуальной» (§8.6). У сессии события всегда `false`: клауза адресована ad-hoc
        /// поимённо, а `graceEndsAt` у сессии без события нет — считать его не от чего.
        let adHocTargetLost: Bool

        /// УМОЛЧАНИЕ У ЧЕТВЁРТОЙ КЛАУЗЫ — РЕШЕНИЕ, И ОНО НАЗВАНО. `false` значит «сессия
        /// события», у которой этой клаузы нет ни на одном входе. Довод тот же, что у
        /// `SessionSide`: вход, собранный векторами строк 2—10, ad-hoc не описывает, и
        /// требовать от них четвёртой клаузы значит обязать их знать о пятом правиле §5.4,
        /// к которому они не относятся. **Цена названа:** вход ad-hoc, собранный вручную и
        /// забывший клаузу, строки 9 по ней не получит — потому фаза сроков и читает её
        /// одним местом, `isAdHocTargetLost(_:now:)`.
        init(
            state: MeetingStatus,
            deadlines: ScheduledArm?,
            eventGone: Bool,
            gate: RecordingGate,
            silenceStopsAt: Date?,
            adHocTargetLost: Bool = false
        ) {
            self.state = state
            self.deadlines = deadlines
            self.eventGone = eventGone
            self.gate = gate
            self.silenceStopsAt = silenceStopsAt
            self.adHocTargetLost = adHocTargetLost
        }
    }

    /// Строка, которой команда `startRecording(meetingId:)` уводит сессию события в
    /// `recording`, — либо `nil`, если из этого состояния такой строки в таблице нет.
    ///
    /// Строк ровно две, и обе названы §8.2 издания v7: **6** из `armed` и **8** из
    /// `awaitingSignal`. Прочие состояния строки в `recording` не имеют ни одной: из
    /// `scheduled` в таблице стоят только строки 2 и 3, из `processing` — 14 и 15, а
    /// переход помимо таблицы запрещён инвариантом 2.
    static func commandRow(from state: MeetingStatus) -> DeadlineRow? {
        switch state {
        case .armed:
            return .row6ArmedToRecording
        case .awaitingSignal:
            return .row8AwaitingSignalToRecording
        case .scheduled, .recording, .stopping, .processing, .ready, .failed, .skipped:
            return nil
        }
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
            return fromAwaitingSignal(input, now: now)
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
    ///
    /// ЧЕТВЁРТАЯ БЕССРОКОВАЯ КЛАУЗА — `adHocTargetLost`, И ОНА СТОИТ СТРОКОЙ ТАБЛИЦЫ, А НЕ
    /// ПОМИМО НЕЁ. Строка 9 издания v6 несёт её дословно: «у ad-hoc-сессии — её цель
    /// перестала быть актуальной (§8.6)». Часть B исполняла это обещание отдельным
    /// проходом `withdrawStaleAdHoc` и называла расхождение доко́вым блоком («строки таблицы
    /// §7 у этого перехода нет»); блок отстал от контракта — строка есть, и переход идёт ею.
    ///
    /// ПОРЯДОК КЛАУЗ ПРАВЛЕН ЧАСТЬЮ C, И ЭТО НЕ КОСМЕТИКА. Часть B читала `eventGone`
    /// ПРЕЖДЕ замка строки 8 — то есть отдавала победу строке 9 там, где истинны обе. §7
    /// говорит обратное дословно: «строки проверяются в порядке таблицы: первое подошедшее
    /// условие побеждает», а 8 стоит раньше 9. Вход достижим — событие отменено, а созвон в
    /// эту минуту звучит, цель свободна и политика её отдаёт, — и §9.2 отвечает на него тем
    /// же: «отменённое в календаре событие не делает несостоявшимся созвон, который в эту
    /// минуту звучит». Ни один пункт перечня этого входа не подаёт (К37 подаёт четыре
    /// бессроковые причины порознь, без цели), и потому расхождение названо строкой отчёта.
    /// В `fromArmed` порядок ОБРАТНЫЙ и не тронут: там строка 4 стоит раньше строки 6, и
    /// побеждает `skipped` — ровно это и проверяет К45 (iii).
    private static func fromAwaitingSignal(_ input: DeadlineInput, now: Date) -> DeadlineRow? {
        if input.gate.maySwitchToRecording { return .row8AwaitingSignalToRecording }
        if input.eventGone { return .row9AwaitingSignalToSkipped }
        if input.adHocTargetLost { return .row9AwaitingSignalToSkipped }
        if let deadlines = input.deadlines, now >= deadlines.graceEndsAt {
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
