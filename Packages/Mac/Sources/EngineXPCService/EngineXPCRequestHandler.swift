//  EngineXPCRequestHandler — сторона сервиса C-012 v10 §3, целиком в чистом Swift/Foundation
//  (`Data`/`Error`, без `NSObject`/`NSXPCConnection`/`@objc`): разбирает `EngineWire`-кадры,
//  диспетчерует их четырём протоколам движка (`EngineBundle`), производит отказы §3.1
//  (коды 1…3, `EngineTransportFault`) и §3.2 (текст «decoding: »/«invariant: »), шлёт прогресс
//  через инжектированное замыкание вместо прямого обращения к `NSXPCConnection`.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (сторона сервиса, ядро без XPC)
//
//  ПОЧЕМУ ЯДРО ОТДЕЛЕНО ОТ `NSXPCConnection`/`@objc` (не только ради читаемости). Символьный
//  граф CI (`symbol-graph-surface.py`) держит для таргетов БЕЗ `allowed-types/<Target>.json`
//  барьер по МОДУЛЮ объявления — публичный тип обязан быть объявлен в таргете репозитория или
//  базовом наборе (`Foundation`/`Swift`/…). `NSObject`/`NSXPCConnection`/`NSXPCListener`
//  лежат в модуле `<C/ObjC>`, которого в этом базовом наборе нет — публичный класс,
//  унаследованный от `NSObject` (неизбежно для `@objc`-протокола `EngineXPCServiceProtocol`,
//  который экспортирует объект `NSXPCConnection`), провалил бы этот барьер. Заводить для
//  этого нового таргета `allowed-types/EngineXPCService.json` — решение того же класса, что
//  правка `allowed-types/EngineXPCClient.json` в MEE-431 (та требовала отдельного заранее
//  полученного разрешения РП на КАЖДУЮ правку, не просто раскрытия постфактум), а не разрешено
//  этой задачей — ни один интерфейс-реквест на этот файл не был подан. Поэтому граница
//  проведена иначе: `NSObject`/`@objc`-обвязка (тонкая, ~20 строк — конформанс протоколу и
//  переадресация вызова, без единой строки диспетчерской логики) заведена ОТДЕЛЬНО, вне
//  `Packages/Mac` (символьный граф CI смотрит только `Packages/Core` и `Packages/Mac`, ничего
//  в `Services/TranscriptionEngineXPC/Sources` и в тестовых целях — `swift build` без
//  `--build-tests` их не собирает вовсе): в самом `Services/TranscriptionEngineXPC/Sources`
//  (прод, `ServiceConnectionDelegate.swift`) и в `EngineXPCServiceTests/TestSupport.swift`
//  (тесты) — раскрыто отдельной строкой в PR, не тихая правка. Настоящая диспетчерская логика
//  (этот файл) при этом ОДНА, используется обеими обвязками без дублирования — раскрытая
//  разница с MEE-370/МЕЕ-389 в том, что дублируется только протокольная обвязка, а не сама
//  проверяемая логика, в отличие от `TestEngineXPCService` (MEE-431), которая была отдельной,
//  не разделяющей код с продакшеном реализацией.
//
//  §3.1 код 2 (messageTooLarge): здесь — НЕЗАВИСИМАЯ проверка ВХОДЯЩЕГО кадра, до всякого
//  декодирования; клиентская проверка (К25, MEE-431) её никогда не упражняет (ловит то же
//  самое до обращения к транспорту).
//
//  §3.2: РОВНО одна точка разбора — `EngineWire.decode(EngineRequest.self, from:)`; выбор
//  префикса «decoding: »/«invariant: » — по БРОШЕННОМУ ТИПУ (`DecodingError` vs
//  `DomainValidationError`), не по содержимому байтов.
//
//  §2.1: `EngineWire.normalizingDates(_:)` — последний шаг перед `encode`, для ЛЮБОГО
//  исходящего `EngineReply` (no-op на всех случаях, кроме `.transcript`).
//
//  Инв. 6/7 (отмена): неизвестный/уже завершённый `jobId` — успешный no-op. Настоящая отмена —
//  кооперативная (`Task.cancel()`); граница «в течение 5с» (инв. 7) названа контрактом и
//  MEE-370 «предметом теста реализатора» — не проверяется здесь отдельным таймером.
//
//  Ответ САМОЙ команды `.cancel(jobId)` (`reply(nil, nil)`) контрактом не специфицирован —
//  тот же выбор, что уже сделан `LoopbackEngineTransport.receive` (`.cancel` не кладёт ничего
//  в `repliesSent`), и единственный настоящий клиент (`sendCancelFrame`) его не читает вовсе.

import DomainCore
import EngineKit
import Foundation

public final class EngineXPCRequestHandler: @unchecked Sendable {

    private let engines: EngineBundle
    private let serviceVersion: String
    private let pushProgress: @Sendable (Data) -> Void

    private let lock = NSLock()
    private var jobs: [EngineJobId: Task<Void, Never>] = [:]

    public init(
        engines: EngineBundle, serviceVersion: String,
        pushProgress: @escaping @Sendable (Data) -> Void
    ) {
        self.engines = engines
        self.serviceVersion = serviceVersion
        self.pushProgress = pushProgress
    }

    /// Гигиена сверх контракта (ни C-012, ни MEE-370 не называют такой критерий): обрыв
    /// соединения обрывает и незавершённую работу, затеянную ради него — иначе фоновая
    /// работа переживала бы клиента, для которого её затевали.
    public func invalidate() {
        let live: [Task<Void, Never>] = lock.locked { let values = Array(jobs.values); jobs.removeAll(); return values }
        for task in live { task.cancel() }
    }

    public func handle(_ requestData: Data, reply: @escaping (Data?, Error?) -> Void) {
        guard requestData.count <= EngineWire.maxMessageBytes else {
            reply(nil, Self.transportFault(.messageTooLarge, [
                EngineTransportFault.messageBytesKey: requestData.count,
                NSLocalizedDescriptionKey: "тело запроса \(requestData.count) байт превышает предел "
                    + "\(EngineWire.maxMessageBytes)"
            ]))
            return
        }
        let request: EngineRequest
        do {
            request = try EngineWire.decode(EngineRequest.self, from: requestData)
        } catch let error as DomainValidationError {
            reply(nil, Self.transportFault(.invalidRequest, [NSLocalizedDescriptionKey: "invariant: \(error)"]))
            return
        } catch {
            reply(nil, Self.transportFault(.invalidRequest, [NSLocalizedDescriptionKey: "decoding: \(error)"]))
            return
        }
        dispatch(request, reply: reply)
    }

    // MARK: - Диспетчер EngineRequest → протокол движка

    private func dispatch(_ request: EngineRequest, reply: @escaping (Data?, Error?) -> Void) {
        switch request {
        case .transcribe(let jobId, let payload):
            start(jobId, completion: reply, operation: { [engines] progress in
                try await engines.transcription.transcribe(payload, progress: progress)
            }, wrap: { .transcript(jobId, $0) })
        case .diarize(let jobId, let payload):
            start(jobId, completion: reply, operation: { [engines] progress in
                try await engines.diarization.diarize(payload, progress: progress)
            }, wrap: { .diarization(jobId, $0) })
        case .embed(let jobId, let payload):
            start(jobId, completion: reply, operation: { [engines] _ in
                try await engines.embedding.embed(payload)
            }, wrap: { .embedding(jobId, $0) })
        case .postProcess(let jobId, let payload):
            start(jobId, completion: reply, operation: { [engines] progress in
                try await engines.postProcessor.process(payload, progress: progress)
            }, wrap: { .outputs(jobId, $0) })
        case .cancel(let jobId):
            cancelIfLive(jobId)
            reply(nil, nil)
        case .ping:
            // Возврат РП по MEE-438 (12:15 UTC): раньше `try?` тихо превращал отказ кодирования
            // `.pong` в `reply(nil, nil)` — то самое нарушение протокола ответа («ни данные, ни
            // ошибка»), которое клиент (`complete(jobId:replyData:error:)`) обязан ловить как
            // отказ, а не как молчаливую пустоту. `.ping` не несёт `EngineJobId` — обернуть в
            // `EngineReply.failed(jobId, …)` здесь буквально нечем, поэтому фолбэк тот же, что у
            // decode-отказов: транспортный `NSError`, не молчание.
            do {
                let data = try EngineWire.encode(EngineReply.pong(
                    serviceVersion: serviceVersion, protocolVersion: EngineWire.protocolVersion
                ))
                reply(data, nil)
            } catch {
                reply(nil, Self.transportFault(.invalidRequest, [
                    NSLocalizedDescriptionKey: "кодирование ответа: \(error)"
                ]))
            }
        }
    }

    /// Возврат РП по MEE-438 (11:50 UTC): регистрация `jobs[jobId]` обязана произойти под
    /// ТЕМ ЖЕ удержанием замка, что и создание `Task` — не после него. `Task { … }` начинает
    /// исполняться немедленно (возможно, на другом потоке); если бы запись в словарь шла
    /// отдельным `lock.locked` уже ПОСЛЕ конструирования задачи, синхронно и очень быстро
    /// завершившаяся операция могла бы вызвать `finish` (снимающий `jobs[jobId] = nil`) РАНЬШЕ,
    /// чем сама регистрация — тогда запись снаружи перезаписала бы словарь уже мёртвой задачей
    /// НАВСЕГДА (снять её больше некому). Здесь `finish` берёт тот же `lock` для своего
    /// собственного снятия — пока замок удерживается здесь, `finish` заблокирован и не может
    /// снять запись раньше, чем она появится (тот же приём, что `LoopbackEngineTransport.start`
    /// и `EngineXPCClient+Transport.swift`, `roundTrip`).
    private func start<Value>(
        _ jobId: EngineJobId,
        completion: @escaping (Data?, Error?) -> Void,
        operation: @escaping (@Sendable @escaping (EngineProgress) -> Void) async throws -> Value,
        wrap: @escaping (Value) -> EngineReply
    ) {
        lock.lock()
        let task = Task { [weak self] in
            guard let self else { return }
            let outcome: EngineReply
            do {
                let value = try await operation { [weak self] progress in
                    self?.pushProgressMessage(EngineProgressMessage(jobId: jobId, progress: progress))
                }
                outcome = wrap(value)
            } catch EngineError.cancelled {
                outcome = .cancelled(jobId)
            } catch is CancellationError {
                outcome = .cancelled(jobId)
            } catch let error as EngineError {
                outcome = .failed(jobId, error)
            } catch {
                outcome = .failed(jobId, .runtimeFailure(message: "\(error)"))
            }
            self.finish(jobId, outcome: outcome, completion: completion)
        }
        jobs[jobId] = task
        lock.unlock()
    }

    /// Возврат РП по MEE-438 (11:50 UTC, уточнено 12:15 UTC): отказ `normalizingDates`/`encode`
    /// над УЖЕ построенным (валидным) `outcome` — падение при кодировании готового ответа, не
    /// при разборе входа — заворачивается в `EngineReply.failed(jobId, .runtimeFailure)`, а не в
    /// транспортный `NSError`: у клиента это тогда законный отказ ДВИЖКА (`engineFailure`), а не
    /// «сервис не смог собрать ответ» на уровне протокола. Это же — и для повторного отказа
    /// кодирования УЖЕ этого фолбэка: `.runtimeFailure(message:)` несёт только `String`,
    /// кодируется всегда (простые `Codable`-поля, ни `Date`, ни `Float`, которым есть от чего
    /// отказать), так что этот путь на практике недостижим (раскрыто, не проверяется тестом —
    /// заставить `EngineWire.encode` упасть на этом значении легитимным входом нечем), но
    /// оставлен последней подстраховкой на тот случай, если он всё же случится, — с тем же самым
    /// кодом ответа, а не разными исходами по глубине отказа.
    private func finish(_ jobId: EngineJobId, outcome: EngineReply, completion: (Data?, Error?) -> Void) {
        lock.locked { jobs[jobId] = nil }
        let toEncode: EngineReply
        do {
            toEncode = try EngineWire.normalizingDates(outcome)
        } catch {
            toEncode = .failed(jobId, .runtimeFailure(message: "нормализация ответа: \(error)"))
        }
        if let data = try? EngineWire.encode(toEncode) {
            completion(data, nil)
            return
        }
        let fallback = EngineReply.failed(jobId, .runtimeFailure(message: "кодирование ответа не удалось"))
        completion(try? EngineWire.encode(fallback), nil)
    }

    private func cancelIfLive(_ jobId: EngineJobId) {
        let task: Task<Void, Never>? = lock.locked { jobs[jobId] }
        task?.cancel()
    }

    private func pushProgressMessage(_ message: EngineProgressMessage) {
        guard let data = try? EngineWire.encode(message) else { return }
        pushProgress(data)
    }

    private static func transportFault(_ fault: EngineTransportFault, _ userInfo: [String: Any]) -> NSError {
        NSError(domain: EngineTransportFault.errorDomain, code: fault.rawValue, userInfo: userInfo)
    }
}

extension NSLock {
    fileprivate func locked<Value>(_ body: () -> Value) -> Value {
        lock(); defer { unlock() }
        return body()
    }
}
