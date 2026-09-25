//  FakeSessionCoordinator — реализация `SessionCoordinator` поверх заданного тестом
//  состояния. C-018 §«Фейк для тестов», критерий К87 плана MEE-288.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Состав взят у контракта дословно: «набор `SessionSnapshot`, набор `SessionPrompt`,
//  возможность протолкнуть ЛЮБОЙ `SessionChange` в поток `changes()`, заставить ЛЮБУЮ команду
//  бросить ЛЮБУЮ `SessionError`, записать все вызванные команды с аргументами и отдать их
//  тесту списком». Кому именно он пригоден в коде — решает К88 плана MEE-288
//  (`SessionCoordinatorFakeTraceTests.swift`), не эта шапка.
//
//  СЛОВО «ЛЮБОЙ» ВЕРНО ДОСЛОВНО, И ЭТО НЕСУЩЕЕ СВОЙСТВО, А НЕ ОГОВОРКА. Контракт говорит
//  прямо: фейк ВПРАВЕ отдать снимок, которого верная машина не отдаст, — например
//  `recordingId == nil` в состоянии `recording`, — иначе ветку «фасад пережил негодный вход»
//  не проверить ничем. Отсюда устройство, и оно проверяется К87:
//
//    * `sessions()` отдаёт ЗАДАННОЕ ТЕСТОМ, не фильтруя терминальные и не сортируя по
//      `sessionId`. Клаузы контракта «нетерминальные, по возрастанию `sessionId`» —
//      обязанность машины, и фейк их не исполняет;
//    * ни одно поле снимка не приводится ни к чему: ни `recordingId` к состоянию, ни
//      `estimate` к `0...1`, ни `meetingId` к `origin`;
//    * `prompts()` отдаёт заданное, не проверяя, что у `.whichMeeting` кандидаты стоят по
//      возрастанию, а `sessionId` равен первому из них.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ МАШИНЫ: из того, что он отдаёт, не следует ни одного разрешения
//  реализатору `domain-core`. Приведи фейк снимок к инвариантам машины — `precondition` или
//  зажатием, — он стал бы красен на входе К87, и цена этого названа контрактом: проверка
//  снялась бы у ЧУЖОГО модуля.
//
//  ЧАСОВ У ФЕЙКА НЕТ НИ ОДНИХ, и `ManualClock` он не требует: §4 C-018 берёт время
//  параметром `now: Date`, и заданный тестом момент есть ЗНАЧЕНИЕ, а не средство. Моменты
//  команд фейк только записывает.
//
//  `@unchecked Sendable` с замком, а не актор: `SessionCoordinator` объявлен `: Sendable`,
//  а `changes()` синхронен, и актором протокол не покрыть.

import Foundation
import DomainCore

/// Команда машины с её аргументами, в том виде, в каком её получил фейк.
public enum SessionCommand: Equatable, Sendable {
    case startRecording(meetingId: UUID?, now: Date)
    case stopRecording(recordingId: UUID, now: Date)
    case skip(meetingId: UUID, now: Date)
    case answer(promptId: UUID, answer: SessionPromptAnswer, now: Date)
    case start(now: Date)
    case tick(now: Date)
    case stop
}

/// Адрес заданного тестом отказа. Бросают только четыре команды §3.1 — остальные три
/// метода протокола `throws` не объявлены, и заставить их бросить нечем.
public enum SessionCommandKind: String, Sendable, CaseIterable {
    case startRecording
    case stopRecording
    case skip
    case answer
}

/// Фейк машины состояний сессии. Всё поведение задаёт тест.
public final class FakeSessionCoordinator: SessionCoordinator, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "SessionCoordinator"

    private let lock = NSLock()
    private let log: PortCallLog

    private var snapshots: [SessionSnapshot] = []
    private var raisedPrompts: [SessionPrompt] = []
    private var failures: [SessionCommandKind: SessionError] = [:]
    private var commands: [SessionCommand] = []
    private var plannedRecordingIds: [UUID] = []
    private var nextNumber = 1
    private var continuations: [AsyncStream<SessionChange>.Continuation] = []

    public init(log: PortCallLog = PortCallLog()) {
        self.log = log
    }

    /// Журнал, в который пишет этот фейк. Тот же объект, что передали в инициализатор.
    public var callLog: PortCallLog { log }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    /// Задать набор снимков. Отдаётся `sessions()` как есть — без отбора и без сортировки.
    public func setSessions(_ list: [SessionSnapshot]) {
        locked { snapshots = list }
    }

    /// Задать набор спросов. Отдаётся `prompts()` как есть.
    public func setPrompts(_ list: [SessionPrompt]) {
        locked { raisedPrompts = list }
    }

    /// Заставить названную команду бросить заданную `SessionError`; `nil` снимает отказ.
    public func fail(_ kind: SessionCommandKind, with error: SessionError?) {
        locked { failures[kind] = error }
    }

    /// Задать наперёд `recordingId`, которые вернут следующие вызовы `startRecording`.
    /// Кончились заданные — фейк продолжает счётчиком.
    public func setNextRecordingIds(_ list: [UUID]) {
        locked { plannedRecordingIds = list }
    }

    /// Идентификатор, который `startRecording` вернёт `n`-м, если наперёд ничего не задано.
    public static func deterministicId(_ number: Int) -> UUID {
        InMemoryTranscriptRepository.deterministicId(number)
    }

    /// Протолкнуть изменение в поток. Значение не приводится ни к чему и доходит как есть —
    /// в том числе снимок, которого верная машина не отдаст.
    public func emit(_ change: SessionChange) {
        let targets = locked { continuations }
        for continuation in targets {
            continuation.yield(change)
        }
    }

    /// Закрыть поток: подписчики досматривают выданное и выходят из цикла.
    public func finishChanges() {
        let targets = locked { () -> [AsyncStream<SessionChange>.Continuation] in
            let taken = continuations
            continuations = []
            return taken
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    /// Все вызванные команды с аргументами, в порядке вызовов, — контракт дословно.
    public var recordedCommands: [SessionCommand] {
        locked { commands }
    }

    // MARK: - Оснастка

    private func throwIfAsked(_ kind: SessionCommandKind) throws {
        if let error = locked({ failures[kind] }) {
            throw error
        }
    }

    // MARK: - SessionCoordinator: чтение

    public func sessions() async -> [SessionSnapshot] {
        log.record(port: Self.portName, method: "sessions()")
        return locked { snapshots }
    }

    public func session(id: UUID) async -> SessionSnapshot? {
        log.record(port: Self.portName, method: "session(id:)", arguments: [id.uuidString])
        return locked { snapshots.first { $0.sessionId == id } }
    }

    public func prompts() async -> [SessionPrompt] {
        log.record(port: Self.portName, method: "prompts()")
        return locked { raisedPrompts }
    }

    public func changes() -> AsyncStream<SessionChange> {
        log.record(port: Self.portName, method: "changes()")
        return AsyncStream { continuation in
            locked { continuations.append(continuation) }
        }
    }

    // MARK: - SessionCoordinator: команды

    public func startRecording(meetingId: UUID?, now: Date) async throws -> UUID {
        log.record(
            port: Self.portName,
            method: "startRecording(meetingId:now:)",
            arguments: [meetingId?.uuidString ?? "nil", String(now.timeIntervalSince1970)]
        )
        locked { commands.append(.startRecording(meetingId: meetingId, now: now)) }
        try throwIfAsked(.startRecording)
        return locked { () -> UUID in
            if plannedRecordingIds.isEmpty {
                let identifier = Self.deterministicId(nextNumber)
                nextNumber += 1
                return identifier
            }
            return plannedRecordingIds.removeFirst()
        }
    }

    public func stopRecording(recordingId: UUID, now: Date) async throws {
        log.record(
            port: Self.portName,
            method: "stopRecording(recordingId:now:)",
            arguments: [recordingId.uuidString, String(now.timeIntervalSince1970)]
        )
        locked { commands.append(.stopRecording(recordingId: recordingId, now: now)) }
        try throwIfAsked(.stopRecording)
    }

    public func skip(meetingId: UUID, now: Date) async throws {
        log.record(
            port: Self.portName,
            method: "skip(meetingId:now:)",
            arguments: [meetingId.uuidString, String(now.timeIntervalSince1970)]
        )
        locked { commands.append(.skip(meetingId: meetingId, now: now)) }
        try throwIfAsked(.skip)
    }

    public func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws {
        log.record(
            port: Self.portName,
            method: "answer(promptId:_:now:)",
            arguments: [promptId.uuidString, String(describing: answer), String(now.timeIntervalSince1970)]
        )
        locked { commands.append(.answer(promptId: promptId, answer: answer, now: now)) }
        try throwIfAsked(.answer)
    }

    // MARK: - SessionCoordinator: жизнь машины

    public func start(now: Date) async {
        log.record(port: Self.portName, method: "start(now:)", arguments: [String(now.timeIntervalSince1970)])
        locked { commands.append(.start(now: now)) }
    }

    public func tick(now: Date) async {
        log.record(port: Self.portName, method: "tick(now:)", arguments: [String(now.timeIntervalSince1970)])
        locked { commands.append(.tick(now: now)) }
    }

    public func stop() async {
        log.record(port: Self.portName, method: "stop()")
        locked { commands.append(.stop) }
    }
}
