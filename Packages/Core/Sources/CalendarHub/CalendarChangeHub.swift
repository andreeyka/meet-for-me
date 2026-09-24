//  Поток changes() и его читатели — C-005 «Поведение» п.3, К62/К63.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен
//
//  ПОЧЕМУ ХАБ ЖИВЁТ ОТДЕЛЬНО ОТ АКТОРА И ПОД ЗАМКОМ — тот же довод, что у
//  `SessionChangeHub` (DomainCore, C-018): `changes()` в C-005 «Определение» объявлен НЕ
//  `async` — актор-изолированный метод этой подписи не удовлетворяет протокольное
//  требование (нужен был бы `async`), значит `changes()` обязан быть `nonisolated`, а
//  `nonisolated`-метод не имеет прямого синхронного доступа к состоянию актора
//  (`changeContinuations` было бы actor-isolated). Хаб — обычный класс под `NSLock`,
//  актор публикует в него, `changes()` только форвардит `hub.subscribe()`.
//
//  БЕЗ СНИМКА ПРИ ПОДПИСКЕ — в отличие от `SessionChangeHub` (инвариант 21 C-018).
//  К62 прямо запрещает обратное: «подписчик не получает ничего про уже случившееся при
//  самой подписке — поток пуст до первого НОВОГО изменения». Начальное состояние читается
//  отдельно, через `events(from:to:)` (К40).
//
//  К63: одна публикация расходится на все живые потоки в одном порядке — `yield` под тем
//  же замком, что регистрация/снятие подписчика, тем же приёмом, что `SessionChangeHub`.

import Foundation
import DomainCore

final class CalendarChangeHub: @unchecked Sendable {

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<CalendarChange>.Continuation] = [:]

    /// Новый поток на каждый вызов, пустой до первого изменения после подписки (К62).
    func subscribe() -> AsyncStream<CalendarChange> {
        AsyncStream<CalendarChange> { continuation in
            let key = UUID()
            lock.lock()
            continuations[key] = continuation
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

    /// К63: та же последовательность на всех живых подписчиков — один вызов, общий замок.
    func publish(_ change: CalendarChange) {
        lock.lock()
        for continuation in continuations.values {
            continuation.yield(change)
        }
        lock.unlock()
    }
}
