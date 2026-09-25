//  CallSlotWaiter — один ожидающий слота К12 (MEE-386, `StdioCalendarConnector.swift`). Отдельный
//  файл — тот же приём file_length/type_body_length, что уже развёл `CalendarPortImpl.swift` на
//  три файла: SwiftLint считает каждый файл отдельно, не суммой по модулю.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation

/// Три явных состояния, не голый `continuation: T?` — возврат РП (MEE-386, комментарий 10:05):
/// более ранняя версия держала `register()`-эквивалент (`suspend()`) как ОТДЕЛЬНЫЙ неизолированный
/// `async`-метод этого класса — по SE-0338 вызов неизолированной `async`-функции уходит с актора
/// вызывающей стороны СРАЗУ, ещё до выполнения её тела, а не только если/когда она подвиснет.
/// Значит между `callSlotWaiters.append(waiter)` (на акторе, `acquireCallSlot()`) и тем моментом,
/// когда `suspend()` внутри себя сохранял continuation, было настоящее окно: `releaseCallSlot()`
/// того же актора (от ДРУГОГО, параллельно завершающегося вызова) мог застать `continuation ==
/// nil`, счесть ждущего отменённым и уйти дальше — сам ждущий, уже вычеркнутый из очереди, чуть
/// позже спокойно сохранял continuation, который теперь уже НИКТО не разбудит (вечное зависание
/// без гонки с таймаутом вовсе; а если гонка с таймаутом всё же есть — по видимости с внешней
/// стороны это неотличимо от настоящего `.timeout`, хотя причина не в реальной медлительности).
/// `callSlotHeld` при этом уже снят — следующий, третий вызов проходит МИМО очереди, будто слот
/// свободен.
///
/// Правка (тот же возврат) — на ДВУХ уровнях: `StdioCalendarConnector.acquireCallSlot()` больше
/// не зовёт отдельный `async`-метод этого класса — `withCheckedThrowingContinuation` вызывается
/// НАПРЯМУЮ внутри изолированного метода актора (тот же приём, что уже принятая очередь
/// `CalendarPortImpl.ensureInitialized`) — тело её замыкания исполняется синхронно, на акторе,
/// без хопа, так что `register()` (ниже) гарантированно успевает сохранить continuation ДО
/// следующей точки приостановки. И ДОПОЛНИТЕЛЬНО, чтобы не полагаться только на это рассуждение
/// о планировщике: сам `CallSlotWaiter` устойчив к любому порядку — `grant()`/`cancel()` раньше
/// `register()` запоминают исход состоянием, а `register()` тогда же и разбудит continuation, не
/// потеряв его.
///
/// Не `private`: возврат РП (комментарий 10:05, тест «выдача раньше подвешивания») проверяет
/// этот тип напрямую, в отрыве от актора — `@testable import` поднимает видимость до `internal`,
/// не до `private` (та осталась бы файл-областной).
final class CallSlotWaiter: @unchecked Sendable {
    private enum State {
        case waiting
        case registered(CheckedContinuation<Void, Error>)
        case granted
        case cancelled
    }

    private let lock = NSLock()
    private var state: State = .waiting

    /// Вызывается СИНХРОННО внутри `withCheckedThrowingContinuation`, напрямую в изолированном
    /// `acquireCallSlot()` — см. докстринг типа. `.granted`/`.cancelled` здесь означают, что
    /// `grant()`/`cancel()` уже отработали РАНЬШЕ (не должно случаться при вызове напрямую из
    /// актора, но `CallSlotWaiter` не полагается на это в одиночку) — тогда будит немедленно
    /// вместо того, чтобы молча сохранить continuation, который уже некому разбудить.
    func register(_ continuation: CheckedContinuation<Void, Error>) {
        let outcome: State = {
            lock.lock()
            defer { lock.unlock() }
            let previous = state
            if case .waiting = previous {
                state = .registered(continuation)
            }
            return previous
        }()
        switch outcome {
        case .waiting:
            return
        case .granted:
            continuation.resume()
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        case .registered:
            preconditionFailure("CallSlotWaiter.register() вызван дважды на одном ожидающем")
        }
    }

    /// Вызывается `onCancel`, вне изоляции актора — только через замок, никогда напрямую
    /// `callSlotWaiters`.
    func cancel() {
        let toResume: CheckedContinuation<Void, Error>? = {
            lock.lock()
            defer { lock.unlock() }
            defer { state = .cancelled }
            if case .registered(let continuation) = state {
                return continuation
            }
            return nil
        }()
        toResume?.resume(throwing: CancellationError())
    }

    /// Отдаёт слот этому ожидающему — `false`, если он уже отменён или уже выдан (`releaseCallSlot()`
    /// тогда переходит к следующему в очереди, не считая слот освобождённым). `.waiting` — слот
    /// закреплён за этим ждущим НЕМЕДЛЕННО (возвращает `true`), даже если `register()` ещё не
    /// вызван: сам факт «выдача раньше подвешивания» разбужен будет `register()`'ом, как только
    /// тот случится (см. его докстринг) — слот при этом не «повисает» ничьим ни на миг.
    func grant() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .waiting:
            state = .granted
            return true
        case .registered(let continuation):
            state = .granted
            continuation.resume()
            return true
        case .granted, .cancelled:
            return false
        }
    }

    /// Только для тестов: ещё не разрешён (ни выдан, ни отменён) — не считает уже выданных/отменённых,
    /// которые могли остаться в `callSlotWaiters` до следующего прохода `releaseCallSlot()`.
    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .waiting, .registered: return true
        case .granted, .cancelled: return false
        }
    }
}
