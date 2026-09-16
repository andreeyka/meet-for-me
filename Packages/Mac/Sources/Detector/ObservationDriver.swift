//  ObservationDriver и ObservationClock — откуда наблюдение берёт «пора посмотреть» и «сколько
//  сейчас». Швы Ш4 и Ш6 перечня MEE-75.
//
//  * Ш4: наблюдение получает состояние мира из ОДНОГО места — источника снимков
//    (`ProcessSnapshotSource`), — и берёт у него пару «содержание + момент» (свойства (i) и
//    (ii)); момент подачи задаёт драйвер (свойство (iii)). В тесте оба заменяются значением, и
//    возврат управления из шага означает, что снимок уже обработан.
//  * Ш6: решение «пора подтверждать» (инвариант 24) читает момент только у `ObservationClock`.
//    В тесте ход времени задаёт тест.
//
//  Предметы швов разные, и здесь они разведены нарочно: момент СНИМКА приходит входом Ш4 (ii)
//  и уезжает в `observedAt`; момент ПУБЛИКАЦИИ наблюдение спрашивает у часов Ш6 и решает им
//  срок подтверждения. Часы момента снимка не подменяют ничем — иначе К51 и К62 сверяли бы
//  одну величину с самой собой.
//
//  Подстановка стоит ниже всего, что утверждают критерии: сравнение состояния, дедупликацию,
//  срок подтверждения, `observedAt`, вес и провайдера исполняет настоящий `SignalEngine`.

import Foundation

/// Источник текущего момента. Шов Ш6.
protocol ObservationClock: Sendable {
    func now() -> Date
}

/// Часы машины — единственное место модуля, где момент берётся у системы. Ими же `HALProcessSource`
/// помечает снятый снимок: в живой работе оба момента приходят отсюда, но в разные мгновения —
/// снимок раньше, публикация позже, — а в тесте их задают врозь два разных входа.
struct SystemClock: ObservationClock {
    func now() -> Date { Date() }
}

/// Кто и как часто зовёт шаг наблюдения. Шов Ш4.
protocol ObservationDriver: Sendable {
    /// Начать звать `step` с шагом не больше `interval` секунд.
    func start(interval: TimeInterval, step: @escaping @Sendable () -> Void)
    /// Перестать звать шаг.
    func stop()
}

/// Драйвер приложения: таймер на собственной последовательной очереди.
final class TimerDriver: ObservationDriver, @unchecked Sendable {

    private let queue = DispatchQueue(label: "meetforme.detector.observation")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    func start(interval: TimeInterval, step: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler(handler: step)
        lock.lock()
        timer?.cancel()
        timer = source
        lock.unlock()
        source.resume()
    }

    func stop() {
        lock.lock()
        let current = timer
        timer = nil
        lock.unlock()
        current?.cancel()
    }
}
