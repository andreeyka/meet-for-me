//  Машина состояний сессии — реализация `SessionCoordinator` по контракту C-018 (MEE-276).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТИ A (MEE-298) и B (MEE-300). Частью A реализованы: тождество и терминальность
//  (§1, §3.1), время параметром (§4), вход и подписки (§2), собственный календарный сигнал
//  (§5.2), звучащая цель и отнесение (§5.3, §5.4), оценка (§6), девять строк таблицы §7 —
//  1, 1а, 1б, 2, 3, 4, 5, 7, 9 — и политики §8.1—§8.3. Частью B добавлены: строки 6, 8 и
//  10—16, §7.1, §8.4, §8.6, §8.7, питание §9.3 и календарь §9.2 в состояниях записи.
//
//  ЧАСТЬЮ C (MEE-307) добавлены: `Scheduler` целиком (§3.2, §9.1 `plan`, §9.2/§9.3
//  `reschedule`, инвариант 15 `nextDeadline`) — `SessionMachineScheduler.swift`; и
//  восстановление §10 перечнями А и Б — `SessionMachineRecovery.swift`. Там же правлены
//  правило `1а` §5.4, четвёртая бессроковая клауза строки 9 и третья клауза строк 6 и 8
//  («команда отдала цель»), вышедшие изданиями v6 и v7 ПОСЛЕ частей A и B.
//
//  ПОЧЕМУ АКТОР, А ПОТОК — ПОД ЗАМКОМ. §«Поведение» требует изоляции актором, и она здесь
//  есть; но `changes()` объявлен §3.1 НЕ `async`, и подписка обязана работать до заведения
//  сессии и до `start(now:)` (условие `П` плана MEE-288 §2). Изолированный метод был бы
//  `async` и подписи не покрыл бы. Отсюда `nonisolated changes()` поверх `SessionChangeHub`
//  — разбор и цена в шапке того файла и в отчёте MEE-298.
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
    /// Пришёл ли ответ `.record`: политика `.ask` открыта (§8.2).
    var recordAnswered: Bool
    /// Отдала ли цель КОМАНДА `startRecording(meetingId:)` (§8.2, издание v7).
    ///
    /// Третья клауза строк 6 и 8 — «запись разрешена политикой» — истинна у сессии события
    /// с момента вызова команды, и истинна она при ЛЮБОЙ политике, включая `.manual`:
    /// «политика описывает автоматику, а команда есть прямое указание человека»
    /// (§«Поведение»). Поле живёт рядом с `recordAnswered`, а не вместо него, потому что
    /// поводов у одной клаузы два и снимаются они разными входами.
    var commandGaveTarget: Bool
    /// `appKey` цели, ради которой заведена ad-hoc-сессия. Живёт всю её жизнь и не
    /// обнуляется вместе с `target`: §8.6 снимает спрос, когда цель перестала быть
    /// АКТУАЛЬНОЙ, а `target` к этой минуте уже `nil` — по нему причину не прочесть.
    /// У `origin == .scheduled` всегда `nil`.
    var adHocAppKey: String?
    /// `observedAt` последней актуальной звучащей цели — момент отсчёта §8.4.
    /// Момент замечания машиной здесь не хранится и храниться не должен: К57 подаёт
    /// задержку замечания именно затем, чтобы эти два момента различались.
    var lastTargetObservedAt: Date?
    /// Токен удержания C-008, взятый при входе в `recording` (инвариант 19).
    var powerToken: PowerActivityToken?
}

/// Реализация `SessionCoordinator`.
public actor SessionMachine: SessionCoordinator {

    // MARK: - Входы §2

    let processes: ProcessMonitorPort
    let calendar: CalendarPort
    let meetings: MeetingRepository
    let recordings: RecordingRepository
    let transcripts: TranscriptRepository
    let capture: AudioCapturePort
    let queue: JobQueue
    let power: PowerPort
    let settings: AppSettings
    let weights: SignalWeights

    // MARK: - Четыре поля `CaptureRequest`, у которых источника в контрактах нет

    /// Каталог записи. По §«Данные на границе» машина получает его ОТ ХРАНИЛИЩА и передаёт
    /// в захват не разбирая; средство — `FileLayout` (C-010 §1) — в дереве не объявлено
    /// вовсе. Взято по конвенции §3 правил проекта: каталог приходит функцией от
    /// `recordingId`, машина его не строит и не читает. Разбор и цена — в отчёте MEE-300.
    ///
    /// `async throws` добавлены MEE-440 (возврат РП, MEE-434 09:15 UTC): замыкание — тонкая
    /// обвязка над `RecordingRepository.createDirectory(recordingId:)` (сам порт — `async
    /// throws`, как и весь остальной `RecordingRepository`), которая обязана бросать
    /// `StorageError.io` на отказе файловой системы, а не молча возвращать URL несуществующего
    /// каталога (composition root раньше глотал этот отказ `try?`). Существующие замыкания
    /// (продакшн и тесты), ни одно не асинхронное и не бросающее, остаются валидны без правки —
    /// Swift сам приводит `(UUID) -> URL` к `(UUID) async throws -> URL` на месте передачи
    /// значения.
    let recordingDirectory: @Sendable (UUID) async throws -> URL

    /// `input`, `systemFormat`, `micFormat` `CaptureRequest`: ни C-018, ни `AppSettings`
    /// (C-016 §2) не называют для них ни значения, ни источника. Тот же исход, тот же
    /// довод — берутся у composition root, машина своих чисел не заводит.
    let captureInput: InputSelection
    let systemFormat: TrackFormat
    let micFormat: TrackFormat

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

    /// Задачи цепочки §8.7: `jobId` → `sessionId`. Чужой `jobId` в ней не лежит, и на этом
    /// стоит «на чужой `attribute` не происходит ничего» (К42).
    var chainJobs: [UUID: UUID] = [:]

    /// События захвата и очереди, пришедшие к ЭТОМУ `tick`. Живут от первой фазы до фазы
    /// сроков одного хода и чистятся в его конце: строки 11—15 читаются в порядке таблицы
    /// вместе со строками 10 и 12, а не прежде них. Разбор и цена — в шапке
    /// `SessionMachineProcessing.swift`.
    var arrivedCapture: [CaptureEvent] = []
    var arrivedJobs: [JobEvent] = []

    /// События питания, пришедшие к этому `tick`. Живут до фазы 1 и там же чистятся:
    /// `didWake` зовёт `reschedule(now:)`, и зовёт его ход времени, а не команда (§9.3).
    var arrivedPower: [PowerEvent] = []

    var subscriptions: [Task<Void, Never>] = []
    var isStarted = false

    /// - Parameters:
    ///   - weights: значения таблицы весов C-009, прочитанные публичным членом `domain-core`
    ///     (`SignalWeights.current()`). Машина не читает файла, не знает пути к нему и
    ///     своего декодера не заводит (§5.2, последний абзац).
    ///   - recordingDirectory: каталог записи по её `recordingId` — см. поле выше.
    public init(
        processes: ProcessMonitorPort,
        calendar: CalendarPort,
        meetings: MeetingRepository,
        recordings: RecordingRepository,
        transcripts: TranscriptRepository,
        capture: AudioCapturePort,
        queue: JobQueue,
        power: PowerPort,
        settings: AppSettings,
        weights: SignalWeights,
        recordingDirectory: @escaping @Sendable (UUID) async throws -> URL,
        captureInput: InputSelection,
        systemFormat: TrackFormat,
        micFormat: TrackFormat
    ) {
        self.processes = processes
        self.calendar = calendar
        self.meetings = meetings
        self.recordings = recordings
        self.transcripts = transcripts
        self.capture = capture
        self.queue = queue
        self.power = power
        self.settings = settings
        self.weights = weights
        self.recordingDirectory = recordingDirectory
        self.captureInput = captureInput
        self.systemFormat = systemFormat
        self.micFormat = micFormat
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

    // MARK: - Жизнь машины §3.1

    /// Подписки на входы §2 и восстановление §10.
    ///
    /// Подписка на `signals()` — ОДНА на приложение (инвариант 11): повторный `start(now:)`
    /// без `stop()` второй не заводит.
    ///
    /// ПОДПИСКИ СТАВЯТСЯ ПРЕЖДЕ ВОССТАНОВЛЕНИЯ, И ЭТО РЕШЕНИЕ. Восстановление §10 читает
    /// только хранилище и ни одного входа §2 не ждёт — порядок его ответа не меняет ни на
    /// одном входе. Но публикация, пришедшая ВО ВРЕМЯ восстановления, при обратном порядке
    /// пропала бы: `signals()` отдаёт снимок при подписке и изменения ПОСЛЕ неё, и того,
    /// что случилось до, не отдаёт никто. **Цена взятого:** вход, легший в ящик во время
    /// восстановления, применяется первым `tick`, а не `start`-ом, — ровно как всякий иной
    /// вход §2 (§«Поведение»).
    ///
    /// СРОКОВ `start(now:)` НЕ ИСПОЛНЯЕТ НИ ОДНОГО — разбор и цена в шапке
    /// `SessionMachineRecovery.swift`.
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

        await recoverFromStorage(now: now)   // §10, перечни А и Б
    }

    /// Ход времени §4. Порядок фаз назван §«Поведение» и исполнен здесь дословно.
    public func tick(now: Date) async {
        let opened = await applyArrivals(now: now)      // фаза 1: пришедшие события и заведение
        recompute(now: now)                             // фаза 2: оценка и звучащая цель
        publish(opened)                                 // снимки заведённых — уже с целью
        await runDeadlines(now: now)                    // фаза 3: сроки в порядке строк §7
        raiseDuePrompts(now: now)
        updateDisputePrompts(now: now)
        updateAdHoc(now: now)                           // строка 1в §8.6
        arrivedCapture.removeAll()                      // вход живёт один ход, не дольше
        arrivedJobs.removeAll()
    }

    /// Снятие подписок. Идущую запись `stop()` НЕ останавливает: `stop()` захвата не
    /// зовётся, токен не отпускается, состояние `recording` сохраняется — §«Поведение»
    /// требует именно этого, и красит обратное К85 (i).
    public func stop() async {
        for task in subscriptions { task.cancel() }
        subscriptions.removeAll()
        isStarted = false
    }

    // MARK: - Переход и публикация

    /// Инвариант 18: запись `setStatus` идёт ПРЕЖДЕ публикации снимка, и порядок значим.
    ///
    /// Здесь же исполняется вторая половина инварианта 19: токен питания отпускается при
    /// выходе из множества `{recording, stopping}` — ПО ЛЮБОМУ пути таблицы, включая
    /// строку 11 (`recording → failed`, минуя `stopping`). Место одно намеренно:
    /// отпускание, приделанное к строкам порознь, течёт на той строке, которую забыли.
    func transition(_ identifier: UUID, to state: MeetingStatus, now: Date) async throws {
        guard var session = store[identifier], session.state != state else { return }
        if let meetingId = session.meetingId {
            try await meetings.setStatus(state, meetingId: meetingId)
            storedStatuses[meetingId] = state
        }
        let wasCapturing = session.state == .recording || session.state == .stopping
        let isCapturing = state == .recording || state == .stopping
        session.state = state
        session.enteredStateAt = now
        session.updatedAt = now
        if wasCapturing, !isCapturing {
            session.powerToken?.end()
            session.powerToken = nil
        }
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
    func latestSession(meeting meetingId: UUID) -> SessionMachineSession? {
        let owned = store.values.filter { $0.meetingId == meetingId }
        return owned.first { !$0.state.isTerminalSession } ?? owned.first
    }

    func requireLive(_ session: SessionMachineSession) throws {
        guard session.state.isTerminalSession else { return }
        throw SessionError.sessionIsTerminal(sessionId: session.sessionId, state: session.state)
    }
}
