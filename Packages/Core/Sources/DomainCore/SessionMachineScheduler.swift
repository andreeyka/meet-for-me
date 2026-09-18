//  `Scheduler` — контракт C-018 (MEE-276), §3.2, §9.1, §9.2 и §9.3.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ C задачи MEE-307.
//
//  ПОЧЕМУ `Scheduler` РЕАЛИЗОВАН ТЕМ ЖЕ ТИПОМ, А НЕ ВТОРЫМ. §9 контракта говорит это
//  прямо: «`Scheduler` описан здесь, ВТОРЫМ ЛИЦОМ ОДНОЙ МАШИНЫ, а не собственным
//  контрактом», и довод у него три части — общий словарь, один переход на шве (строка 2) и
//  один реализатор. Здесь то же самое читается ещё и механически: `nextDeadline(now:)`
//  обязан взять ближайший срок ЖИВОЙ СЕССИИ (инвариант 15), а живые сессии живут в памяти
//  машины и больше нигде. Второй тип пришлось бы либо пустить в её состояние, либо завести
//  ему второе такое же — то есть второе место, где написаны сроки.
//
//  `start(now:)` И `stop()` ОБЪЯВЛЕНЫ ОБОИМИ ПРОТОКОЛАМИ С ОДНОЙ ПОДПИСЬЮ, и потому их
//  здесь нет: одна реализация в `SessionMachine.swift` покрывает обе. Названо, а не
//  умолчано: читатель, не нашедший их в этом файле, иначе решил бы, что они забыты.
//
//  ЗДЕСЬ НЕТ НИ ОДНОГО `Date()` И НИ ОДНОГО ТАЙМЕРА (К9). `Scheduler` не будит машину сам —
//  он ОТВЕЧАЕТ, когда её обязан разбудить composition root (§8.5), и обязанность звать
//  `tick` достаточно часто лежит на нём, а не здесь (§4, граница).

import Foundation

extension SessionMachine: Scheduler {

    // MARK: - §3.2: план

    /// Все встречи, удовлетворяющие §9.1, по возрастанию `armAt`; при равенстве — по
    /// `meetingId`.
    ///
    /// КЛАУЗ ЧЕТЫРЕ, А НЕ ПЯТЬ, И ЧЕТВЁРТАЯ ИЗ НИХ — НЕ «НЕТ ЖИВОЙ СЕССИИ». §9.1 разбирает
    /// «таких событий» по клаузам сам, и это издание v6: событие входит в ответ, если
    /// истинны три первые клаузы условия заведения — `isAllDay == false`,
    /// `isCancelled == false`, `now ≤ graceEndsAt` — И хранимый `MeetingStatus` встречи не
    /// терминален; клауза «у встречи нет живой сессии» к `plan(now:)` НЕ ПРИМЕНЯЕТСЯ.
    ///
    /// **Довод сужения отвергнут контрактом вслух, и цена названа им же:** ветвь инварианта
    /// 17 «заведённая раньше и живая» подаётся строкой плана И ТОЛЬКО ЕЮ, и реализация,
    /// сузившая план до встреч без живой сессии, делает её недостижимой молча (К71 вектор
    /// (б), К74 вектор (а)). Цена взятого — `nextDeadline(now:)` держит `armAt` встречи с
    /// живой сессией, и composition root зовёт `tick`, который по ней ничего не меняет;
    /// контракт называет это верным поведением, а не лишним ходом.
    ///
    /// ЧИСТАЯ ФУНКЦИЯ ОТ ХРАНИЛИЩА, `AppSettings` И `now` (инвариант 16). Ни `knownEvents`,
    /// ни `storedStatuses`, ни `deletedEvents` здесь не читаются и не пишутся: это память
    /// МАШИНЫ, а не содержимое хранилища, и ответ, стоящий на ней, зависел бы от того,
    /// сколько `tick`-ов прошло до вызова. Состояния ни одной сессии вызов не меняет.
    public func plan(now: Date) async throws -> [ScheduledArm] {
        try await planned(now: now).map { SessionMachineRules.arm(for: $0.event, settings: settings) }
    }

    /// Строки хранилища, из которых строится план. Отдельным членом, потому что читателей
    /// два — `plan(now:)` и `nextDeadline(now:)`, — а чтение обязано быть одно.
    private func planned(now: Date) async throws -> [MeetingRecord] {
        let from = now.addingTimeInterval(-TimeInterval(settings.missingSignalGraceSeconds))
        let records = try await meetings.meetings(from: from, to: Date.distantFuture)
        return records
            .filter { !$0.event.isAllDay }
            .filter { !$0.event.isCancelled }
            .filter { !$0.status.isTerminalSession }
            .filter { now <= SessionMachineRules.arm(for: $0.event, settings: settings).graceEndsAt }
            .sorted { lhs, rhs in
                let left = SessionMachineRules.arm(for: lhs.event, settings: settings)
                let right = SessionMachineRules.arm(for: rhs.event, settings: settings)
                if left.armAt != right.armAt { return left.armAt < right.armAt }
                return SessionMachineOrder.ascending(lhs.event.id, rhs.event.id)
            }
    }

    // MARK: - §3.2: ближайший срок

    /// Ближайший момент, в который состояние машины обязано измениться; `nil` — сроков нет
    /// ни одного (инвариант 15).
    ///
    /// СРОК В ПРОШЛОМ ЗАКОНЕН И ОБЯЗАТЕЛЕН, А НЕ ПОДРЕЗАЕТСЯ ДО `now`. §10 говорит это
    /// дословно: «сессия, заведённая при уже прошедшем сроке, даёт `nextDeadline(now:)` в
    /// прошлом (инвариант 15)», и ровно этим §10 заставляет первый `tick` после
    /// `start(now:)` прийти немедленно — §8.5 обязывает composition root звать `tick` не
    /// позже ближайшего `nextDeadline(now:)`. Реализация, отдающая здесь `max(срок, now)`
    /// либо снимающая прошедшие сроки, оставила бы восстановленную сессию ждать общего
    /// периода, и обещание §10 не исполнялось бы ничем.
    ///
    /// СРОКИ СЕССИИ ЕСТЬ ФУНКЦИЯ ЕЁ СОСТОЯНИЯ, и потому уже исполненные в набор не
    /// попадают: из `armed` сессия не ждёт `armAt`, потому что строка 2 по ней уже
    /// сработала. Перечисление ниже тотально по девяти значениям `MeetingStatus`.
    public func nextDeadline(now: Date) async throws -> Date? {
        var moments: [Date] = []
        for session in store.values where !session.state.isTerminalSession {
            moments.append(contentsOf: deadlines(of: session))
        }
        for record in try await planned(now: now) {
            moments.append(SessionMachineRules.arm(for: record.event, settings: settings).armAt)
        }
        return moments.min()
    }

    /// Сроки одной живой сессии — те, что ей ещё предстоят.
    ///
    /// `stopping` и `processing` не ждут ни одного срока: их исходящие строки — 12, 13, 14
    /// и 15 — наступают по приходу `CaptureEvent` и `JobEvent`, а не по сроку, и назвать
    /// момент их прихода машина не может ничем.
    private func deadlines(of session: SessionMachineSession) -> [Date] {
        guard let event = session.event else {
            // Ad-hoc-сессия: `armAt`, `askAt`, `e.start` и `graceEndsAt` считаются от
            // события, которого у неё нет, — сроков у неё нет ни одного, кроме срока §8.4
            // в `recording` (К95, последнее предложение).
            return session.state == .recording ? silenceDeadlines(of: session) : []
        }
        let arm = SessionMachineRules.arm(for: event, settings: settings)
        switch session.state {
        case .scheduled:
            return [arm.armAt, arm.graceEndsAt] + askDeadline(of: session, arm: arm)
        case .armed:
            return [arm.startsAt, arm.graceEndsAt] + askDeadline(of: session, arm: arm)
        case .awaitingSignal:
            return [arm.graceEndsAt] + askDeadline(of: session, arm: arm)
        case .recording:
            return silenceDeadlines(of: session)
        case .stopping, .processing, .ready, .failed, .skipped:
            return []
        }
    }

    /// Момент `askAt`, пока спрос по нему ещё не поднят и ответа не было (§8.2). При
    /// политиках, отличных от `.ask`, `askAt == nil`, и срока нет ни одного.
    private func askDeadline(of session: SessionMachineSession, arm: ScheduledArm) -> [Date] {
        guard let askAt = arm.askAt, session.promptId == nil, !session.recordAnswered else {
            return []
        }
        return [askAt]
    }

    /// Момент §8.4 — `recording → stopping` по тишине; `nil`, если цели не было ни разу.
    private func silenceDeadlines(of session: SessionMachineSession) -> [Date] {
        guard let observedAt = session.lastTargetObservedAt else { return [] }
        return [SessionMachineRules.silenceStopsAt(
            lastTargetObservedAt: observedAt, settings: settings, weights: weights
        )]
    }

    // MARK: - §9.2 и §9.3: пересчёт

    /// Календарь изменился, настройки изменились, система проснулась.
    ///
    /// ВТОРОГО МЕХАНИЗМА ИСПОЛНЕНИЯ СРОКОВ ЗДЕСЬ НЕТ НИ ОДНОГО, И ЭТО ТРЕБОВАНИЕ, А НЕ
    /// СКРОМНОСТЬ. §9.3: «сроки, пройденные во сне, исполняются первым `tick` после
    /// пробуждения — это инвариант 14 дословно, отдельного правила для сна не заводится».
    /// Отсюда `reschedule(now:)` читает хранилище и на этом кончается: ни одного перехода,
    /// ни одной публикации, ни одного вызова захвата (К68).
    ///
    /// Сроки нигде не хранятся — они функция от события и настроек (§9.2), — и потому
    /// «пересчитать» значит взять из хранилища действующие события, а не тронуть пять полей
    /// порознь. Ровно это и делает `readStorage(now:)`, одно на обоих читателей.
    public func reschedule(now: Date) async {
        await readStorage(now: now)
        refreshSessionEvents()
    }
}
