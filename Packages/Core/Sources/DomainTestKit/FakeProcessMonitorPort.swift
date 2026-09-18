//  FakeProcessMonitorPort — реализация `ProcessMonitorPort` в памяти, C-009 §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Управляется тестом целиком: список процессов задаётся и меняется на лету, в поток `signals()`
//  проталкивается ЛЮБОЙ `MeetingSignal` с любой `ProcessGroup`, `startObserving()` заставляется
//  бросить, вызовы считаются.
//
//  Слово «любой» здесь сознательное и держится шапкой раздела «Инварианты» [v5, IR-048]: фейк
//  не связан обязанностями публикующей стороны (инварианты 11, 12, 15, 17, 18), потому что его
//  значение — вход, выбранный тестом, а не утверждение о наблюдаемом мире. Поэтому сигнал,
//  который настоящий порт отдать не вправе, проходит здесь НЕИЗМЕНЁННЫМ: без этого ветку
//  «потребитель пережил негодный вход от сломанного адаптера» не проверить ничем.
//
//  Цена сказана там же и повторена здесь, потому что молчание о границе читается как её
//  отсутствие: ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА. Из того, что он отдаёт, не следует ни одного
//  разрешения реализатору `detector` — поведение порта описывает контракт, и только он.
//
//  MEE-290 ДОБАВИЛ СЮДА СЧЁТЧИК ВЫЗОВОВ `signals()`, и ни одного ответа это не меняет.
//  Он условие `О` плана MEE-288 §2 и нужен К13, который без него не исполняется ничем:
//  реализацию, подписывающуюся на `signals()` при заведении каждой сессии, красит только
//  счёт подписок — поведение обеих сессий на фейке, отдающем всем подписчикам одно и то же,
//  совпадает. Текст контракта C-009 не тронут ни символом: §«Фейк для тестов» называет счёт
//  `startObserving`/`stopObserving` и счёта подписок не называет и не запрещает.
//
//  MEE-307 ДОБАВИЛ СЮДА СНИМОК ПРИ ПОДПИСКЕ — `setSnapshot(_:)`, — и это условие `Ю`
//  постановки. Разбор и цена стоят при самом средстве; коротко: без него вход «машина
//  поднялась над уже идущим созвоном» (К15, К95, К97) не подать ничем, а обход через
//  «подписаться, потом опубликовать» проверяет машину, стартовавшую в пустом мире.
//
//  ЖУРНАЛА ВЫЗОВОВ У ЭТОГО ФЕЙКА НЕТ, И ЭТО НЕ ПРОПУСК: условие `Н` перечисляет фейки
//  репозиториев C-010, очереди C-013, захвата C-004 и питания C-008 — наблюдения C-009 в нём
//  нет, и ни один пункт плана порядка вызовов этого порта не требует.
//
//  `@unchecked Sendable` с замком, а не актор: `ProcessMonitorPort` объявлен `: Sendable`,
//  а его методы — не `async` целиком (`signals()` синхронен), и актором протокол не покрыть.

import Foundation
import DomainCore

/// Фейк порта наблюдения за процессами. Всё поведение задаёт тест.
public final class FakeProcessMonitorPort: ProcessMonitorPort, @unchecked Sendable {

    private let lock = NSLock()
    private var processes: [AudioProcess] = []
    private var continuations: [AsyncStream<MeetingSignal>.Continuation] = []
    private var snapshot: [MeetingSignal] = []
    private var startFailure: ProcessMonitorError?
    private var startCalls = 0
    private var stopCalls = 0
    private var signalsCalls = 0

    public init() {}

    /// Замок вокруг состояния. Своя обёртка, а не `NSLocking.withLock`: та пришла в Foundation
    /// позже минимальной версии тулчейна, на которой собирается работа CI `Core (Linux)`.
    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    /// Задать или сменить снимок процессов на лету.
    public func setProcesses(_ list: [AudioProcess]) {
        locked { processes = list }
    }

    /// Протолкнуть сигнал в поток. Значение не приводится ни к чему и доходит как есть.
    public func emit(_ signal: MeetingSignal) {
        let targets = locked { continuations }
        for continuation in targets {
            continuation.yield(signal)
        }
    }

    /// Задать СНИМОК АКТУАЛЬНОГО — то, что поток отдаёт КАЖДОМУ подписчику прежде живых
    /// публикаций (C-009, инвариант 26). Пустой по умолчанию.
    ///
    /// ЗАЧЕМ ОН ЗАВЕДЁН, И ЭТО НЕ УДОБСТВО. До него подписка только дописывала
    /// `continuation` в список, а `emit(_:)` отдавал значение лишь тем, кто подписан НА
    /// МОМЕНТ публикации: сигнал, поданный ДО подписки, не был виден никому. Между тем
    /// восстановление §10 C-018 начинается ровно с того, что машина поднимается НАД УЖЕ
    /// СУЩЕСТВУЮЩИМ миром — созвон шёл до её запуска, — и подать такой вход было нечем.
    /// Обход (подписаться, потом опубликовать) проверяет не то: он проверяет машину,
    /// стартовавшую в пустом мире.
    ///
    /// ПОЧЕМУ ОТДЕЛЬНОЕ СРЕДСТВО, А НЕ ПАМЯТЬ `emit`. Отвергнуто — запоминать всё
    /// опубликованное и переигрывать это всякой новой подписке. **Цена отвергнутого:**
    /// снимок по инварианту 26 есть снимок АКТУАЛЬНОГО, а актуальность определяется
    /// сроком `signalTtlSeconds` от `observedAt` относительно «сейчас» (C-009 §1) —
    /// часов у фейка нет ни одних, и он решал бы за тест, что в мире осталось. Взятое
    /// оставляет это решение тесту, ровно как и всё прочее поведение этого фейка.
    ///
    /// **Цена взятого названа:** тест, которому нужен сигнал и в снимке, и в потоке,
    /// говорит это дважды — `setSnapshot(_:)` и `emit(_:)`. Ни одного ответа уже
    /// написанных векторов это не меняет: снимок пуст, пока его не задали.
    public func setSnapshot(_ list: [MeetingSignal]) {
        locked { snapshot = list }
    }

    /// Закрыть поток: подписчики досматривают выданное и выходят из цикла.
    public func finishSignals() {
        let targets = locked {
            let taken = continuations
            continuations = []
            return taken
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    /// Заставить `startObserving()` бросить названную ошибку; `nil` снимает отказ.
    public func failStartObserving(with error: ProcessMonitorError?) {
        locked { startFailure = error }
    }

    /// Счётчик вызовов `startObserving()`.
    public var startObservingCallCount: Int {
        locked { startCalls }
    }

    /// Счётчик вызовов `stopObserving()`.
    public var stopObservingCallCount: Int {
        locked { stopCalls }
    }

    /// Счётчик вызовов `signals()` — условие `О` плана MEE-288 §2, нужен К13.
    ///
    /// **Зачем он, если поведение подписчиков и так наблюдаемо.** К13 красит реализацию,
    /// подписывающуюся на `signals()` ПРИ ЗАВЕДЕНИИ КАЖДОЙ СЕССИИ, — и красит её ТОЛЬКО
    /// этим счётчиком: поведение двух сессий на фейке, отдающем всем подписчикам одно и то
    /// же, совпадает, и различить одну подписку от двух больше нечем.
    ///
    /// **Граница названа:** счётчик считает вызовы `signals()`, а не число ЖИВЫХ
    /// подписок. Подписчик, бросивший поток, из счёта не уходит — его тут и не считают.
    public var signalsCallCount: Int {
        locked { signalsCalls }
    }

    // MARK: - ProcessMonitorPort

    public func audioProcesses() async throws -> [AudioProcess] {
        locked { processes }
    }

    /// Отбор по правилу §4.1 — той же чистой функцией, что и у настоящей реализации.
    public func processes(matching bundleIds: [String]) async throws -> [AudioProcess] {
        locked { processes }
            .filter { process in bundleIds.contains { bundleKeyMatches(appKey: process.appKey, entry: $0) } }
            .sorted { $0.pid < $1.pid }
    }

    /// Поток НАЧИНАЕТСЯ СО СНИМКА АКТУАЛЬНОГО (C-009, инвариант 26), и только за ним идут
    /// публикации, наступившие после подписки. Снимок задаёт тест — `setSnapshot(_:)`.
    ///
    /// Снимок выдаётся ВНУТРИ построителя, до того как `continuation` попадёт в список:
    /// иначе публикация, пришедшая между двумя строками, обогнала бы снимок и порядок
    /// «снимок, потом изменения» перестал бы держаться. `AsyncStream` буферизует выданное
    /// до первого `next()`, и ни одно значение при этом не теряется.
    public func signals() -> AsyncStream<MeetingSignal> {
        locked { signalsCalls += 1 }
        return AsyncStream { continuation in
            locked {
                for signal in snapshot {
                    continuation.yield(signal)
                }
                continuations.append(continuation)
            }
        }
    }

    public func startObserving() async throws {
        let failure = locked { () -> ProcessMonitorError? in
            startCalls += 1
            return startFailure
        }
        if let failure {
            throw failure
        }
    }

    public func stopObserving() async {
        locked { stopCalls += 1 }
    }
}
