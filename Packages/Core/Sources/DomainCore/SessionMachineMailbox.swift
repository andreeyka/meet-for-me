//  Ящик входов машины сессий — контракт C-018 (MEE-276), §2 «Вход машины» и §«Поведение»
//  («вход, пришедший между двумя `tick`, до `tick` состояния не меняет»).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ A задачи MEE-298.
//
//  ЗАЧЕМ ЯЩИК ВООБЩЕ. §«Поведение» называет порядок фаз в один `tick` — сперва применяются
//  пришедшие события, затем пересчитываются оценка и цель, затем проверяются сроки — и
//  говорит, что до `tick` состояния не меняет ничто, кроме команд §3.1. Значит подписки на
//  входы §2 обязаны КЛАСТЬ пришедшее, а не применять: применяет `tick(now:)`. Без ящика К12
//  («`tick` не зовётся вовсе — не наступает ничего») был бы неисполним, а реализация с
//  ленивым пересчётом при чтении — незаметна (вектор К12 её и красит).
//
//  ПОЧЕМУ ЯЩИК ПОД ЗАМКОМ, А НЕ ВНУТРИ АКТОРА. Кладут в него задачи подписок, а они живут
//  своим ходом; изоляция актора заставила бы их ждать занятого `tick`, то есть очередь
//  входов стала бы функцией того, как долго идёт чужой ход. Замок даёт то же без ожидания.
//
//  ОТДЕЛЬНО НАЗВАНО, ПОТОМУ ЧТО ЭТО НАБЛЮДАЕМОСТЬ, А НЕ ПОВЕДЕНИЕ: `waitUntilReceived(_:)`
//  существует ради тестов и ради них одних. Доставка входа из `AsyncStream` порта в ящик
//  асинхронна ПО ПОСТРОЕНИЮ — синхронного способа забрать элемент у `AsyncStream` нет ни
//  одного, — и тест, подавший сигнал и сразу позвавший `tick`, проверял бы расписание
//  исполнителя, а не машину. Ожидание на продолжении, а не на пределе времени, взято
//  намеренно: предел ожидания нестабилен по построению (§7 плана MEE-288, условие `Р`), а
//  продолжение возобновляется ровно тем событием, которого ждут. Член внутримодульный:
//  публичной поверхности он не расширяет ни на символ (П2).

import Foundation

/// Вход машины, пришедший потоком порта (§2). Команды §3.1 сюда не попадают: они
/// исполняются в момент вызова.
enum SessionMachineInput: Sendable {
    case signal(MeetingSignal)
    case calendar(CalendarChange)
    case capture(CaptureEvent)
    case job(JobEvent)
    case power(PowerEvent)
}

/// Очередь входов между двумя `tick`.
final class SessionMachineMailbox: @unchecked Sendable {

    private let lock = NSLock()
    private var pending: [SessionMachineInput] = []
    private var received = 0
    private var waiters: [(needed: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init() {}

    /// Сколько входов ящик принял за свою жизнь. Растёт монотонно и `drain()` его не роняет.
    var receivedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Положить вход. Состояния ни одной сессии это не меняет — меняет его `tick(now:)`.
    func append(_ input: SessionMachineInput) {
        lock.lock()
        pending.append(input)
        received += 1
        let due = waiters.filter { $0.needed <= received }
        waiters.removeAll { $0.needed <= received }
        lock.unlock()
        for waiter in due {
            waiter.continuation.resume()
        }
    }

    /// Забрать всё пришедшее в порядке прихода и опустошить очередь.
    func drain() -> [SessionMachineInput] {
        lock.lock()
        defer { lock.unlock() }
        let taken = pending
        pending.removeAll()
        return taken
    }

    /// Дождаться, пока ящик примет `count` входов за свою жизнь. Наблюдаемость для тестов;
    /// поведения машины этот член не несёт и из её путей не зовётся ни разу.
    func waitUntilReceived(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if received >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((needed: count, continuation: continuation))
            lock.unlock()
        }
    }
}
