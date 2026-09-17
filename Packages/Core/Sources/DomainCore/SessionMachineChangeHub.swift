//  Поток `changes()` машины сессий и снимок при подписке — контракт C-018 (MEE-276),
//  инвариант 21; §3.1.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ A задачи MEE-298. Пути машины — файлы `Sources/DomainCore/SessionMachine*.swift`
//  вместе с объявлениями `SessionCoordinator.swift`; это и есть отделимость, которой просит
//  условие `Т` плана MEE-288 §2, и признак у неё один и механический — имя файла.
//
//  ПОЧЕМУ ХАБ ЖИВЁТ ОТДЕЛЬНО ОТ АКТОРА И ПОД ЗАМКОМ — это решение по условию `П` плана
//  MEE-288 §2, и цена обеих половин названа в отчёте. Коротко: `changes()` объявлен §3.1
//  НЕ `async`, а условие `П` требует подписки ДО заведения сессии, в том числе до
//  `start(now:)`. Метод, изолированный актором, подписи протокола не покрывает — он был бы
//  `async`; а инвариант 21 требует отдать при подписке снимок, то есть прочитать состояние
//  синхронно. Отсюда: зеркало нетерминальных сессий и поднятых спросов живёт здесь, рядом с
//  подписчиками и под тем же замком, а актор его сюда публикует.
//
//  РЕГИСТРАЦИЯ ПОДПИСЧИКА И ВЫДАЧА ЕМУ СНИМКА ИДУТ ПОД ОДНИМ ЗАМКОМ С ПУБЛИКАЦИЕЙ, и это
//  несущее решение, а не осторожность: разними их — и подписка, случившаяся между
//  обновлением зеркала и рассылкой, получила бы одно и то же изменение дважды (снимком и
//  событием) либо не получила бы вовсе. Инвариант 21 говорит «снимок, и только за ним —
//  изменения, наступившие после подписки»; оба исхода его нарушают, и ловит их К82.
//
//  ГРАНИЦА НАЗВАНА: `yield` под замком законен потому, что он кладёт элемент в буфер
//  (`AsyncStream` без политики буферизации — неограниченный) и не зовёт синхронно ни одной
//  строки потребителя. `finish()` под замком не зовётся нигде: его обработчик
//  `onTermination` берёт тот же замок, а `NSLock` не рекурсивен.

import Foundation

/// Терминальные состояния сессии — §7 контракта C-018, абзац под таблицей, и инвариант 3.
///
/// Отображением между двумя перечислениями это не является и являться не может: перечисление
/// состояний одно, и объявлено оно C-010 (§1.2, инвариант 1, К4).
extension MeetingStatus {

    /// `ready`, `failed`, `skipped`: исходящих переходов у них нет ни одного.
    var isTerminalSession: Bool {
        switch self {
        case .ready, .failed, .skipped:
            return true
        case .scheduled, .armed, .awaitingSignal, .recording, .stopping, .processing:
            return false
        }
    }
}

/// Поток изменений машины и зеркало, из которого собирается снимок при подписке.
final class SessionChangeHub: @unchecked Sendable {

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SessionChange>.Continuation] = [:]

    /// Зеркало НЕТЕРМИНАЛЬНЫХ сессий: инвариант 21 отдаёт при подписке именно их.
    private var sessions: [UUID: SessionSnapshot] = [:]

    /// Зеркало поднятых и ещё не снятых спросов, в порядке поднятия.
    private var prompts: [UUID: SessionPrompt] = [:]
    private var promptOrder: [UUID] = []

    init() {}

    /// Замок вокруг состояния. Своя обёртка, а не `NSLocking.withLock`: та пришла в Foundation
    /// позже минимальной версии тулчейна, на которой собирается работа CI `Core (Linux)`.
    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Подписка

    /// Новый поток. Каждый вызов возвращает свой — инвариант 21 дословно.
    func subscribe() -> AsyncStream<SessionChange> {
        AsyncStream<SessionChange> { continuation in
            let key = UUID()
            lock.lock()
            continuations[key] = continuation
            for change in snapshotWhileLocked() {
                continuation.yield(change)
            }
            lock.unlock()
            // Ставится ВНЕ замка: обработчик берёт тот же замок, а он не рекурсивен.
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: key)
                self.lock.unlock()
            }
        }
    }

    /// Снимок: все нетерминальные сессии по возрастанию `sessionId`, затем все поднятые
    /// спросы в порядке поднятия. Предыстории сверх снимка здесь нет ни одного элемента.
    private func snapshotWhileLocked() -> [SessionChange] {
        let ordered = sessions.values.sorted { SessionMachineOrder.ascending($0.sessionId, $1.sessionId) }
        return ordered.map { SessionChange.session($0) }
            + promptOrder.compactMap { prompts[$0] }.map { SessionChange.promptRaised($0) }
    }

    // MARK: - Публикация

    /// Обновить зеркало и разослать изменение целиком каждому живому потоку.
    /// Между подписчиками изменения не делятся: каждому уходит своё значение.
    func publish(_ change: SessionChange) {
        lock.lock()
        apply(change)
        for continuation in continuations.values {
            continuation.yield(change)
        }
        lock.unlock()
    }

    private func apply(_ change: SessionChange) {
        switch change {
        case let .session(snapshot):
            if snapshot.state.isTerminalSession {
                sessions.removeValue(forKey: snapshot.sessionId)
            } else {
                sessions[snapshot.sessionId] = snapshot
            }
        case let .promptRaised(prompt):
            if prompts[prompt.promptId] == nil {
                promptOrder.append(prompt.promptId)
            }
            prompts[prompt.promptId] = prompt
        case let .promptWithdrawn(promptId):
            prompts.removeValue(forKey: promptId)
            promptOrder.removeAll { $0 == promptId }
        }
    }
}

/// Порядок по возрастанию `UUID`. `UUID` не `Comparable`, а «по возрастанию `sessionId`»
/// стоит в §3.1 трижды — у `sessions()`, у `candidates` и у `SessionPrompt.sessionId`.
/// Сравнение идёт по `uuidString`: это те же шестнадцать байт в старшем-первым порядке,
/// и одно место на весь модуль вместо трёх разошедшихся.
enum SessionMachineOrder {

    static func ascending(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}
