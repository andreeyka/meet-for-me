//  Поверхность машины состояний сессии — контракт C-018 (MEE-276),
//  «Определение», §1.1, §3.1 и §3.2
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ТОЛЬКО ОБЪЯВЛЕНИЯ. Ни одной реализации `SessionCoordinator`, ни одной реализации
//  `Scheduler`, ни одной строки таблицы переходов §7 здесь нет и быть не должно:
//  реализация — задача после MEE-290, и постановка MEE-289 запрещает её прямо.
//  Фейк `FakeSessionCoordinator` — предмет MEE-290, каталог DomainTestKit.
//
//  ПОЧЕМУ ПРОТОКОЛЫ ОБЪЯВЛЕНЫ, ХОТЯ §6 ПЛАНА MEE-288 НАЗВАЛ ШЕСТЬ ПОРТОВ, А НЕ ВОСЕМЬ.
//  Тот же §6 требует пунктом 4 завести `FakeSessionCoordinator` (вход К87, след К88) и
//  сам же пунктом 1 говорит: «фейк реализует протокол, и прежде протокола он не пишется
//  ничем». Без объявления `SessionCoordinator` задача MEE-290, ждущая слияния этой,
//  не исполнима в своей части, а К87 остаётся не исполняемым ничем. Запрет постановки
//  MEE-289 назван в ней словом «реализовывать»; объявление протокола реализацией не
//  является и поведения не несёт. Разбор и цена — в отчёте MEE-289.
//
//  `ScheduledArm` и `Scheduler` (§3.2) §6 плана не называет вовсе, а К71 и К74 стоят
//  на ответе `plan(now:)`. Найдено прогоном по §3.2 контракта; названо в отчёте.
//
//  Время параметром, а не часами (§4 контракта): всякий метод, которому нужен «сейчас»,
//  принимает `now: Date`. Порта часов этот контракт не заводит, и здесь его нет.
//
//  Порядок типов и порядок полей внутри типа — дословно по §1.1, §3.1 и §3.2 контракта
//  (порядок значим: правило обхода C-001 §0.2 п. 9).

import Foundation

// MARK: - §1.1. Что такое сессия

public enum SessionOrigin: String, Codable, Sendable {
    case scheduled   // заведена по событию календаря
    case adHoc       // заведена по сигналу; события нет
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let sessionId: UUID
    public let origin: SessionOrigin
    public let meetingId: UUID?          // MeetingEvent.id (C-001); nil ⟺ origin == .adHoc
    public let state: MeetingStatus      // C-010 §5 — девять значений, второго перечисления нет
    public let recordingId: UUID?        // nil до входа в .recording; дальше не меняется
    public let target: ProcessGroup?     // C-009; звучащая цель, выбранная правилом §5.3
    public let estimate: Double          // 0...1; формула C-009 §1. Условием перехода не служит
    public let enteredStateAt: Date      // момент входа в текущее состояние
    public let updatedAt: Date

    public init(
        sessionId: UUID,
        origin: SessionOrigin,
        meetingId: UUID?,
        state: MeetingStatus,
        recordingId: UUID?,
        target: ProcessGroup?,
        estimate: Double,
        enteredStateAt: Date,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.origin = origin
        self.meetingId = meetingId
        self.state = state
        self.recordingId = recordingId
        self.target = target
        self.estimate = estimate
        self.enteredStateAt = enteredStateAt
        self.updatedAt = updatedAt
    }
}

// MARK: - §3.1. SessionCoordinator

public enum SessionPromptKind: Codable, Equatable, Sendable {
    /// «Записать?» — политика .ask либо созвон без события (§8.2, §8.6)
    case recordThisMeeting
    /// Звучащая цель отнеслась к нескольким сессиям и однозначного правила нет (§5.4)
    case whichMeeting(candidates: [UUID])   // sessionId кандидатов, по возрастанию
}

public struct SessionPrompt: Codable, Equatable, Sendable {
    public let promptId: UUID
    public let sessionId: UUID           // у .whichMeeting — первый кандидат по возрастанию
    public let kind: SessionPromptKind
    public let raisedAt: Date
    public let expiresAt: Date?          // nil — спрос держится, пока держится его причина (§8.6)

    public init(
        promptId: UUID,
        sessionId: UUID,
        kind: SessionPromptKind,
        raisedAt: Date,
        expiresAt: Date?
    ) {
        self.promptId = promptId
        self.sessionId = sessionId
        self.kind = kind
        self.raisedAt = raisedAt
        self.expiresAt = expiresAt
    }
}

public enum SessionPromptAnswer: Codable, Equatable, Sendable {
    case record(sessionId: UUID)   // у .recordThisMeeting — sessionId самого спроса
    case skip
}

public enum SessionChange: Equatable, Sendable {
    case session(SessionSnapshot)
    case promptRaised(SessionPrompt)
    case promptWithdrawn(promptId: UUID)
}

public enum SessionError: Error, Codable, Equatable, Sendable {
    case noSuchMeeting(meetingId: UUID)
    case noSuchSession(sessionId: UUID)
    case noSuchPrompt(promptId: UUID)
    case noRecordingInProgress(recordingId: UUID)
    case alreadyRecording(sessionId: UUID)      // эта группа уже записывается другой сессией
    case nothingToRecord                        // цели нет и микрофон не выбран
    case sessionIsTerminal(sessionId: UUID, state: MeetingStatus)
    case capture(CaptureError)                  // C-004, наблюдённый отказ захвата
}

public protocol SessionCoordinator: Sendable {

    // --- Чтение ---
    func sessions() async -> [SessionSnapshot]            // нетерминальные, по возрастанию sessionId
    func session(id: UUID) async -> SessionSnapshot?
    func prompts() async -> [SessionPrompt]
    func changes() -> AsyncStream<SessionChange>          // инвариант 21

    // --- Команды; их зовёт фасад C-016 §4 ---
    func startRecording(meetingId: UUID?, now: Date) async throws -> UUID   // возвращает recordingId
    func stopRecording(recordingId: UUID, now: Date) async throws
    func skip(meetingId: UUID, now: Date) async throws
    func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws

    // --- Жизнь машины ---
    func start(now: Date) async    // восстановление §10, подписки на входы §2
    func tick(now: Date) async     // ход времени §4
    func stop() async              // снятие подписок; идущую запись не останавливает
}

// MARK: - §3.2. Scheduler

/// Что взведено на один будущий созвон. Чистая функция от события, настроек и now.
public struct ScheduledArm: Codable, Equatable, Sendable {
    public let meetingId: UUID
    public let armAt: Date         // startsAt − armLeadSeconds
    public let askAt: Date?        // startsAt − askLeadSeconds; nil при recordingPolicy != .ask
    public let startsAt: Date      // MeetingEvent.start
    public let endsAt: Date        // MeetingEvent.end
    public let graceEndsAt: Date   // startsAt + missingSignalGraceSeconds

    public init(
        meetingId: UUID,
        armAt: Date,
        askAt: Date?,
        startsAt: Date,
        endsAt: Date,
        graceEndsAt: Date
    ) {
        self.meetingId = meetingId
        self.armAt = armAt
        self.askAt = askAt
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.graceEndsAt = graceEndsAt
    }
}

public protocol Scheduler: Sendable {
    /// События, удовлетворяющие §9.1: isAllDay == false, isCancelled == false, now <= graceEndsAt
    /// и хранимый MeetingStatus нетерминален. Клауза «у встречи нет живой сессии» здесь НЕ
    /// применяется — встреча с живой сессией в плане стоит (§9.1, инвариант 17).
    /// Порядок: по возрастанию armAt; при равенстве — по meetingId.
    func plan(now: Date) async throws -> [ScheduledArm]
    /// Ближайший момент, в который состояние машины обязано измениться; nil — сроков нет.
    func nextDeadline(now: Date) async throws -> Date?
    func start(now: Date) async
    func reschedule(now: Date) async   // календарь изменился, настройки изменились, система проснулась
    func stop() async
}
