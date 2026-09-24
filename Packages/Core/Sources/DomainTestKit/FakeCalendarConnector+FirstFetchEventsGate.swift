//  FakeCalendarConnector+FirstFetchEventsGate — ворота на первый вызов fetchEvents, не
//  реагирующие на отмену вызывающей задачи. Вынесено отдельным файлом той же причиной, что
//  развела `CalendarPortImplSync.swift`/`CalendarPortImplMerge.swift`: SwiftLint
//  `type_body_length` считает каждое расширение типа отдельно.
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен (фейки портов для тестов)

import Foundation

extension FakeCalendarConnector {

    /// Возврат РП (24.09, приёмка #119, 22:12 UTC, п. 1): ворота на ПЕРВЫЙ вызов
    /// `fetchEvents`, в отличие от `hangOrGate`, НЕ реагирующие на отмену вызывающей задачи —
    /// нужны там, где задача обязана пережить отмену своего вызывающего (тест «устаревшее
    /// поколение висит вне цепочки mergeTail, пока новое доходит до успеха») и оставаться
    /// управляемой только явным `releaseFirstFetchEventsGate()`. Срабатывают РОВНО РАЗ — на
    /// первом вызове ПОСЛЕ взведения `gateFirstFetchEvents()`: второй и далее проходят
    /// насквозь немедленно, даже если первый ещё не отпущен (тот же довод, что не даёт новому
    /// поколению зависнуть на воротах, заведённых под старое).
    public func gateFirstFetchEvents() {
        locked {
            firstFetchEventsGateArmed = true
            firstFetchEventsGateConsumed = false
        }
    }

    /// Отпускает вызов, ждущий на этих воротах; вызов без ждущего (ворота не взведены или уже
    /// отпущены) — no-op.
    public func releaseFirstFetchEventsGate() {
        let continuation = locked { () -> CheckedContinuation<Void, Never>? in
            let waiting = firstFetchEventsGateContinuation
            firstFetchEventsGateContinuation = nil
            return waiting
        }
        continuation?.resume()
    }

    func waitIfFirstFetchEventsGated() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldWait = locked { () -> Bool in
                guard firstFetchEventsGateArmed, !firstFetchEventsGateConsumed else { return false }
                firstFetchEventsGateConsumed = true
                firstFetchEventsGateContinuation = continuation
                return true
            }
            if !shouldWait { continuation.resume() }
        }
    }
}
