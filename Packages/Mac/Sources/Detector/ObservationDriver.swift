//  ObservationDriver и ObservationClock — откуда наблюдение берёт «пора посмотреть» и «сколько
//  сейчас». Швы Ш4 и Ш6 перечня MEE-75.
//
//  * Ш4: наблюдение получает состояние мира из ОДНОГО места — источника снимков
//    (`ProcessSnapshotSource`), — а момент подачи задаёт драйвер. В тесте оба заменяются
//    значением, и возврат управления из шага означает, что снимок уже обработан.
//  * Ш6: ни решение «пора подтверждать» (инвариант 24), ни момент снимка не берутся у часов
//    машины мимо `ObservationClock`. В тесте ход времени задаёт тест.
//
//  Подстановка стоит ниже всего, что утверждают критерии: сравнение состояния, дедупликацию,
//  срок подтверждения, `observedAt`, вес и провайдера исполняет настоящий `SignalEngine`.

import Foundation

/// Источник текущего момента. Шов Ш6.
protocol ObservationClock: Sendable {
    func now() -> Date
}

/// Часы машины — единственное место модуля, где момент берётся у системы.
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
