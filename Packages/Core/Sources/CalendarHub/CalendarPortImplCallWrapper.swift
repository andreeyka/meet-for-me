//  CalendarPortImpl+CallWrapper — обёртка вызова коннектора: таймаут (К9) + повтор §5.2
//  (К56/К67) + отображение ошибок (К13).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен
//
//  Вынесено из CalendarPortImpl.swift отдельным файлом — тот же приём, что у `capture`
//  (`AudioCaptureImpl+Rebuild.swift` и соседи): SwiftLint `file_length`/`type_body_length`
//  считают КАЖДОЕ расширение типа отдельно, а не суммой по всем файлам модуля.

import Foundation
import DomainCore

extension CalendarPortImpl {

    enum MethodTimeout {
        case initialize, fetchWindow, other
        var duration: Duration {
            switch self {
            case .initialize: return .seconds(10)
            case .fetchWindow: return .seconds(120)
            case .other: return .seconds(30)
            }
        }
        var seconds: Int { Int(duration.components.seconds) }
    }

    private static let fallbackRetryDelays = [1, 2, 4]

    /// К9: таймаут гонкой с Ш3, на границе, не раньше/позже. К56/К67: повтор на
    /// `.rateLimited` — до трёх раз, потолок задержки 60с, отмена во время ожидания —
    /// `.cancelled`, не `.transport`. `retryable: false` — только для `shutdown()`
    /// (инв. 20: «shutdown никогда не повторяется»).
    ///
    /// СТРОКА (найдено буквальным чтением при написании теста К64 вход Б — до этого
    /// теста на `.cursorInvalid` не было вовсе, ни здесь, ни у К55): `passthroughCursorInvalid`
    /// — без него `.cursorInvalid` не матчит `.rateLimited` веткой ниже и уходит через
    /// `else` тем же путём, что и любая другая невосстановимая ошибка — `throw
    /// Self.mapConnectorError(...)` превращает её в `CalendarError` ПРЕЖДЕ, чем вызывающая
    /// сторона (`applyDeltaSync`/`applyFirstDeltaStep`) успевает получить шанс поймать её
    /// СВОИМ `catch let error as ConnectorError` — тот перехватывает `CalendarError`, не
    /// `ConnectorError`, и никогда не срабатывает: ветка восстановления по инв. 19
    /// («забыть курсор, fetchEvents на полном окне») была мертвым кодом. Флаг — исключение
    /// ИМЕННО для этого случая: даёт `.cursorInvalid` пройти наружу СВОИМ типом
    /// (`ConnectorError`, не отображённым), только когда вызывающая сторона объявила, что
    /// сама знает, что с ним делать; по умолчанию `false` — не меняет поведение ни одного
    /// из прочих вызовов `callConnector` в модуле.
    func callConnector<Value: Sendable>(
        source: CalendarSourceId, connector: CalendarConnector, timeout: MethodTimeout,
        retryable: Bool = true, passthroughCursorInvalid: Bool = false,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        var attempt = 0
        while true {
            do {
                return try await raceTimeout(source: source, timeout: timeout, operation: operation)
            } catch let error as ConnectorError {
                if passthroughCursorInvalid, case .cursorInvalid = error {
                    throw error
                }
                guard case .rateLimited(let retryAfterSeconds) = error, retryable, attempt < 3 else {
                    // Развилка Р10: `upstreamUnavailable` — тот же сигнал «переподключить
                    // заново», что таймаут (raceTimeout ниже) — следующий вызов этого
                    // источника инициализирует с нуля, не полагаясь на кэш `capabilities`.
                    if case .upstreamUnavailable = error {
                        capabilities[source] = nil
                    }
                    throw Self.mapConnectorError(error, source: source)
                }
                attempt += 1
                let delay = (0...3600).contains(retryAfterSeconds)
                    ? min(retryAfterSeconds, 60)
                    : Self.fallbackRetryDelays[attempt - 1]
                do {
                    try await waitSeam.sleep(for: .seconds(delay))
                } catch {
                    throw CalendarError.cancelled
                }
            }
        }
    }

    private func raceTimeout<Value: Sendable>(
        source: CalendarSourceId, timeout: MethodTimeout,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let seam = waitSeam   // локальная копия — избегает пересечения изоляции актора
        do {                  // внутри замыканий `group.addTask`, которые вне неё.
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await seam.sleep(for: timeout.duration)
                    throw CalendarError.timeout(sourceId: source, seconds: timeout.seconds)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CalendarError.timeout(sourceId: source, seconds: timeout.seconds)
                }
                return result
            }
        } catch let error as CalendarError {
            if case .timeout = error {
                // К9 вход Б (кадр shutdown на таймауте) — обязанность stdio-адаптера
                // (group Ж, ещё не написан): здесь только сбрасываем кэш `capabilities`,
                // чтобы следующий вызов инициализировал заново (тот же принцип, что К10/Р10).
                // СТРОКА: звать ли `connector.shutdown()` здесь же, для ЛЮБОГО коннектора
                // (не только stdio) — контракт не решает для in-process пути. Не зову: у
                // in-process коннектора зависшая Task не обязана значить «процесс мёртв»
                // (процесса и нет), а К9 вход А не проверяет вызов shutdown — решение
                // оставлено до группы Ж, чтобы не придумывать наблюдаемое поведение, о
                // котором перечень MEE-347 не говорит ни здесь, ни там.
                capabilities[source] = nil
            }
            throw error
        }
    }

    static func mapConnectorError(_ error: ConnectorError, source: CalendarSourceId) -> CalendarError {
        switch error {
        case .authorizationRequired:
            return .authorizationRequired(sourceId: source)
        case .notConfigured:
            return .notConfigured(sourceId: source)
        case .rateLimited(let retryAfterSeconds):
            return .transport(sourceId: source, message: "rateLimited, retryAfter=\(retryAfterSeconds)")
        case .cursorInvalid:
            // СТРОКА: вне fetchChanges (единственное место, где инв. 19 даёт этому случаю
            // смысл) контракт не называет ответ вовсе. Беру protocolViolation — тем же
            // путём, что и прочие «код есть, но своего отображения здесь нет» случаи.
            return .protocolViolation(sourceId: source, message: "cursorInvalid вне fetchChanges")
        case .upstreamUnavailable(let message):
            return .transport(sourceId: source, message: message)
        case .protocolViolation(let message):
            return .protocolViolation(sourceId: source, message: message)
        }
    }
}
