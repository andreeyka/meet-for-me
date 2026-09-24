//  CapturePollDriver — шов периодического перечитывания состава захвата, инвариант 12.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  «Не реже чем раз в capturedProcessesPollSeconds» — образец Detector, ObservationDriver
//  (Ш4): реальная реализация — таймер на своей очереди; фейк теста зовёт шаг вручную и не спит
//  по-настоящему (план MEE-315, «виртуальное время шва»).

import Foundation

protocol CapturePollDriverHandle: Sendable {
    func stop()
}

protocol CapturePollDriver: Sendable {
    /// Начать звать `tick` не реже раза в `seconds`. Возвращает хэндл остановки.
    func start(seconds: Int, tick: @escaping @Sendable () -> Void) -> CapturePollDriverHandle
}

final class SystemPollDriver: CapturePollDriver {

    private final class Handle: CapturePollDriverHandle {
        private let timer: DispatchSourceTimer
        init(_ timer: DispatchSourceTimer) { self.timer = timer }
        func stop() { timer.cancel() }
    }

    func start(seconds: Int, tick: @escaping @Sendable () -> Void) -> CapturePollDriverHandle {
        let queue = DispatchQueue(label: "meetforme.capture.poll")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        timer.setEventHandler(handler: tick)
        timer.resume()
        return Handle(timer)
    }
}
