//  Машина состояний сессии — реализация `SessionCoordinator` по контракту C-018 (MEE-276).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ A задачи MEE-298 — ВСЁ ДО ВХОДА В ЗАПИСЬ, и граница названа здесь, а не оставлена
//  читателю. Реализованы: тождество и терминальность (§1, §3.1), время параметром (§4),
//  вход и подписки (§2), собственный календарный сигнал (§5.2), звучащая цель и отнесение
//  (§5.3, §5.4), оценка (§6), девять строк таблицы §7 из восемнадцати — 1, 1а, 1б, 2, 3, 4,
//  5, 7, 9 — и политики §8.1—§8.3.
//
//  ЧЕГО ЗДЕСЬ НЕТ, И ЭТО ПРЕДМЕТ ДРУГОЙ ЗАДАЧИ, А НЕ ДОЛГ ЭТОЙ:
//  — строки 6, 8 (вход в запись), 10—16 (остановка, отказ, обработка, ad-hoc) — часть B;
//    состояний `recording`, `stopping` и `processing` эта реализация не заводит НИ ОДНИМ
//    входом, и потому их в таблице ниже нет ни строкой;
//  — §7.1 (одна группа — одна запись), §8.4, §8.6, §8.7, питание §9.3 — часть B;
//  — восстановление §10 и `Scheduler` (§3.2, §9.1 `plan`, §9.2) — часть C. `start(now:)`
//    здесь ставит подписки §2 и НЕ восстанавливает: восстановительное заведение таблицей §7
//    не описывается (инвариант 2, исключение), и заводить его вне своей задачи нельзя.
//
//  ПОЧЕМУ АКТОР, А ПОТОК — ПОД ЗАМКОМ. §«Поведение» требует изоляции актором, и она здесь
//  есть; но `changes()` объявлен §3.1 НЕ `async`, и подписка обязана работать до заведения
//  сессии и до `start(now:)` (условие `П` плана MEE-288 §2). Изолированный метод был бы
//  `async` и подписи не покрыл бы. Отсюда `nonisolated changes()` поверх `SessionChangeHub`
//  — разбор и цена в шапке того файла и в отчёте.
//
//  ПУБЛИЧНОСТЬ ТИПА НАЗВАНА РЕШЕНИЕМ. Контракт объявляет протокол и говорит, что машину
//  зовут «из любого контекста, UI — через фасад»: собрать её обязан composition root, и без
//  публичного типа этого не может никто. Разрешённым списком публичная поверхность
//  `domain-core` не описывается — §0 п. 5 контракта, исход (б) IR-066. Ни одного члена
//  сверх протокола тип наружу не отдаёт.
//
//  ВРЕМЯ — ПАРАМЕТРОМ (§4). Ни `Date()`, ни таймера, ни `Task.sleep` на путях машины нет
//  ни одного: всякий срок наступает внутри `tick(now:)`, и если `tick` не приходит, не
//  наступает ничего.

import Foundation

/// Сессия в памяти машины. `SessionSnapshot` — её ответ наружу, а не она сама.
struct SessionMachineSession {
    let sessionId: UUID
    let origin: SessionOrigin
    let meetingId: UUID?
    var state: MeetingStatus
    var recordingId: UUID?
    var target: ProcessGroup?
    var estimate: Double
    var enteredStateAt: Date
    var updatedAt: Date
    /// Последнее известное событие сессии; `nil` у `.adHoc`.
    var event: MeetingEvent?
    /// Спрос `.recordThisMeeting`, поднятый этой сессией.
    var promptId: UUID?
    /// Пришёл ли ответ `.record`: политика `.ask` открыта (§8.2). Строки 6 и 8, которые
    /// этим ответом разрешаются, — часть B задачи.
    var recordAnswered: Bool
}

/// Реализация `SessionCoordinator` — часть A.
public actor SessionMachine: SessionCoordinator {

    // MARK: - Входы §2

    let processes: ProcessMonitorPort
    let calendar: CalendarPort
    let meetings: MeetingRepository
    let capture: AudioCapturePort
    let queue: JobQueue
    let power: PowerPort
    let settings: AppSettings
    let weights: SignalWeights

    // MARK: - Состояние

    let hub = SessionChangeHub()
    let mailbox = SessionMachineMailbox()

    var store: [UUID: SessionMachineSession] = [:]
    var raised: [UUID: (prompt: SessionPrompt, isWithdrawn: Bool)] = [:]
    var promptOrder: [UUID] = []

    /// Последний сигнал каждой пары «вид + источник» (C-009 §1).
    var signals: [SessionMachineRules.SignalPair: MeetingSignal] = [:]

    /// События, известные машине. Содержимое их полей задаёт `CalendarChange`; хранилище
    /// приносит те, которых машина ещё не видела.
    var knownEvents: [UUID: MeetingEvent] = [:]

    /// Встречи, удалённые из календаря (`CalendarChange.deleted`) — клауза строк 3, 4, 9.
    var deletedEvents: Set<UUID> = []

    /// Хранимый `MeetingStatus` встреч, снятый последним чтением хранилища.
    var storedStatuses: [UUID: MeetingStatus] = [:]

    /// Цели, отнесённые сразу к нескольким живым сессиям (§5.4): `appKey` → кандидаты.
    var contested: [String: [UUID]] = [:]

    /// Поднятые спросы `.whichMeeting`: `appKey` спорной цели → `promptId`.
    var disputes: [String: UUID] = [:]

    var subscriptions: [Task<Void, Never>] = []
    var isStarted = false

    /// - Parameters:
    ///   - weights: значения таблицы весов C-009, прочитанные публичным членом `domain-core`
    ///     (`SignalWeights.current()`). Машина не читает файла, не знает пути к нему и
    ///     своего декодера не заводит (§5.2, последний абзац).
    public init(
        processes: ProcessMonitorPort,
        calendar: CalendarPort,
        meetings: MeetingRepository,
        capture: AudioCapturePort,
        queue: JobQueue,
        power: PowerPort,
        settings: AppSettings,
        weights: SignalWeights
    ) {
        self.processes = processes
        self.calendar = calendar
        self.meetings = meetings
        self.capture = capture
        self.queue = queue
        self.power = power
        self.settings = settings
        self.weights = weights
    }

    // MARK: - Чтение §3.1

    /// Только нетерминальные, по возрастанию `sessionId`.
    public func sessions() async -> [SessionSnapshot] {
        store.values
            .filter { !$0.state.isTerminalSession }
            .map(snapshot(of:))
            .sorted { SessionMachineOrder.ascending($0.sessionId, $1.sessionId) }
    }

    /// Любой `id`, включая терминальный; `nil` на незнакомом.
    public func session(id: UUID) async -> SessionSnapshot? {
        store[id].map(snapshot(of:))
    }

    /// Все поднятые и ни одного снятого, в порядке поднятия.
    public func prompts() async -> [SessionPrompt] {
        promptOrder.compactMap { raised[$0] }.filter { !$0.isWithdrawn }.map(\.prompt)
    }

    /// Каждый вызов возвращает свой поток; при подписке он отдаёт снимок (инвариант 21).
    /// `nonisolated`: подпись §3.1 не `async`, и подписка обязана работать до `start(now:)`.
    public nonisolated func changes() -> AsyncStream<SessionChange> {
        hub.subscribe()
    }

    // MARK: - Команды §3.1; исполняются В МОМЕНТ ВЫЗОВА

    /// Часть A вход в `recording` не заводит ни одним ходом: строки 6, 8 и 16 — часть B
    /// задачи. Здесь исполнены только те ответы команды, которые от них не зависят.
    public func startRecording(meetingId: UUID?, now: Date) async throws -> UUID {
        guard let meetingId else {
            // Строка 16 (ad-hoc) — часть B.
            throw SessionError.nothingToRecord
        }
        guard let session = latestSession(meeting: meetingId) else {
            throw SessionError.noSuchMeeting(meetingId: meetingId)
        }
        try requireLive(session)
        // Строки 6 и 8 — часть B.
        throw SessionError.nothingToRecord
    }

    /// Часть A в `recording` не входит, и потому записи, которую эта команда останавливает,
    /// у неё нет ни одной. Строка 10 — часть B задачи.
    public func stopRecording(recordingId: UUID, now: Date) async throws {
        guard let session = store.values.first(where: { $0.recordingId == recordingId }) else {
            throw SessionError.noRecordingInProgress(recordingId: recordingId)
        }
        try requireLive(session)
        throw SessionError.noRecordingInProgress(recordingId: recordingId)
    }

    /// Команда `skip` — строки 3, 4 и 9 таблицы §7.
    ///
    /// Управление не возвращается раньше, чем исход записан `setStatus`-ом (инвариант 18,
    /// вторая половина): запись стоит на пути возврата, а не рядом с ним.
    public func skip(meetingId: UUID, now: Date) async throws {
        guard let session = latestSession(meeting: meetingId) else {
            throw SessionError.noSuchMeeting(meetingId: meetingId)
        }
        try requireLive(session)
        try await transition(session.sessionId, to: .skipped, now: now)
    }

    /// Ответ на спрос §8.2 и §8.6.
    public func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws {
        guard let stored = raised[promptId] else {
            throw SessionError.noSuchPrompt(promptId: promptId)
        }
        guard let session = store[stored.prompt.sessionId] else {
            throw SessionError.noSuchSession(sessionId: stored.prompt.sessionId)
        }
        // Порядок существен: К6 требует `sessionIsTerminal`, а НЕ `noSuchPrompt`, — значит
        // терминальность читается прежде, чем снятость спроса.
        try requireLive(session)
        guard !stored.isWithdrawn else {
            throw SessionError.noSuchPrompt(promptId: promptId)
        }
        switch answer {
        case .skip:
            try await transition(session.sessionId, to: .skipped, now: now)
        case .record:
            // Политика `.ask` открыта; строки 6 и 8, которые ею разрешаются, — часть B.
            var updated = session
            updated.recordAnswered = true
            updated.updatedAt = now
            store[session.sessionId] = updated
            withdrawPrompt(promptId)
        }
    }

    // MARK: - Жизнь машины §3.1

    /// Подписки на входы §2. Восстановление §10 — часть C задачи, и здесь его нет.
    ///
    /// Подписка на `signals()` — ОДНА на приложение (инвариант 11): повторный `start(now:)`
    /// без `stop()` второй не заводит.
    public func start(now: Date) async {
        guard !isStarted else { return }
        isStarted = true

        let box = mailbox
        let signalStream = processes.signals()
        subscriptions.append(Task.detached { for await value in signalStream { box.append(.signal(value)) } })

        let calendarStream = calendar.changes()
        subscriptions.append(Task.detached { for await value in calendarStream { box.append(.calendar(value)) } })

        let captureStream = capture.events()
        subscriptions.append(Task.detached { for await value in captureStream { box.append(.capture(value)) } })

        let jobStream = queue.events()
        subscriptions.append(Task.detached { for await value in jobStream { box.append(.job(value)) } })

        let powerStream = power.events()
        subscriptions.append(Task.detached { for await value in powerStream { box.append(.power(value)) } })
    }

    /// Ход времени §4. Порядок фаз назван §«Поведение» и исполнен здесь дословно.
    public func tick(now: Date) async {
        let opened = await applyArrivals(now: now)      // фаза 1: пришедшие события и заведение
        recompute(now: now)                             // фаза 2: оценка и звучащая цель
        publish(opened)                                 // снимки заведённых — уже с целью
        await runDeadlines(now: now)                    // фаза 3: сроки в порядке строк §7
        raiseDuePrompts(now: now)
        updateDisputePrompts(now: now)
    }

    /// Снятие подписок. Идущей записи у части A нет ни одной, и `stop()` захвата она не
    /// зовёт ни разу — §«Поведение» требует именно этого.
    public func stop() async {
        for task in subscriptions { task.cancel() }
        subscriptions.removeAll()
        isStarted = false
    }

    // MARK: - Переход и публикация

    /// Инвариант 18: запись `setStatus` идёт ПРЕЖДЕ публикации снимка, и порядок значим.
    func transition(_ identifier: UUID, to state: MeetingStatus, now: Date) async throws {
        guard var session = store[identifier], session.state != state else { return }
        if let meetingId = session.meetingId {
            try await meetings.setStatus(state, meetingId: meetingId)
            storedStatuses[meetingId] = state
        }
        session.state = state
        session.enteredStateAt = now
        session.updatedAt = now
        store[identifier] = session
        hub.publish(.session(snapshot(of: session)))
        if state.isTerminalSession, let promptId = session.promptId {
            // Спрос, чья сессия терминальна, ответить нечем: К6 требует `sessionIsTerminal`
            // на `answer`. Запись о спросе поэтому не выбрасывается, а помечается снятой.
            withdrawPrompt(promptId)
        }
    }

    private func publish(_ identifiers: [UUID]) {
        for identifier in identifiers {
            guard let session = store[identifier] else { continue }
            hub.publish(.session(snapshot(of: session)))
        }
    }

    // MARK: - Оснастка

    func snapshot(of session: SessionMachineSession) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: session.sessionId,
            origin: session.origin,
            meetingId: session.meetingId,
            state: session.state,
            recordingId: session.recordingId,
            target: session.target,
            estimate: session.estimate,
            enteredStateAt: session.enteredStateAt,
            updatedAt: session.updatedAt
        )
    }

    /// Сессия встречи: живая, если она есть, иначе последняя терминальная — её и адресуют
    /// команды, и на ней стоит К6.
    private func latestSession(meeting meetingId: UUID) -> SessionMachineSession? {
        let owned = store.values.filter { $0.meetingId == meetingId }
        return owned.first { !$0.state.isTerminalSession } ?? owned.first
    }

    private func requireLive(_ session: SessionMachineSession) throws {
        guard session.state.isTerminalSession else { return }
        throw SessionError.sessionIsTerminal(sessionId: session.sessionId, state: session.state)
    }
}
