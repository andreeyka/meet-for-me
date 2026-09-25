//  EngineXPCClient — соединение, круговой обмен (кадр → ответ), сторож таймаута, приём
//  прогресса. Разведено из `EngineXPCClient.swift` по объёму, не по смыслу.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (клиент NSXPCConnection)

import Foundation
import DomainCore
import EngineKit

extension EngineXPCClient {

    /// Состояние одной незавершённой отправки: продолжение `async`, приёмник прогресса
    /// (`nil` у `ping` — ему прогресс не идёт), момент последней активности (сброс
    /// таймаута) и флаг «уже резолвлено» — гонка ответа с отменой решается тем, кто первый
    /// снимет кадр из `jobs` (К27).
    final class PendingJob: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<EngineReply, Error>?
        let progress: (@Sendable (TranscriptionProgress) -> Void)?
        private var lastActivity: Date

        init(continuation: CheckedContinuation<EngineReply, Error>,
             progress: (@Sendable (TranscriptionProgress) -> Void)?, startedAt: Date) {
            self.continuation = continuation
            self.progress = progress
            self.lastActivity = startedAt
        }

        func touch(_ now: Date) {
            lock.lock(); lastActivity = now; lock.unlock()
        }

        func elapsedSeconds(since now: Date) -> Double {
            lock.lock(); defer { lock.unlock() }
            return now.timeIntervalSince(lastActivity)
        }

        /// Резолвит ровно один раз — второй и далее вызовы (ответ и отмена гонятся за
        /// одним и тем же продолжением) молча не делают ничего.
        func resolve(_ result: Result<EngineReply, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            switch result {
            case .success(let reply): pending.resume(returning: reply)
            case .failure(let error): pending.resume(throwing: error)
            }
        }
    }

    /// `@objc`-объект, которым клиент экспортирует себя сервису (`exportedInterface`) —
    /// нужен отдельный `NSObject`, потому что `EngineXPCClient` не наследует `NSObject`.
    final class ProgressReceiver: NSObject, EngineXPCClientProtocol {
        private let onProgress: @Sendable (Data) -> Void
        init(onProgress: @escaping @Sendable (Data) -> Void) { self.onProgress = onProgress }
        func didReceiveProgress(_ progressData: Data) { onProgress(progressData) }
    }

    // MARK: - Соединение (ленивое, пересоздаваемое — см. заголовок EngineXPCClient.swift)

    /// Прокси сервиса с собственным обработчиком отказа для ЭТОГО конкретного вызова —
    /// отказ на уровне самого прокси (до реплай-блока `send`, например обрыв соединения)
    /// приходит сюда же, не в реплай-блок.
    private func serviceProxy(errorHandler: @escaping @Sendable (Error) -> Void) -> EngineXPCServiceProtocol? {
        currentConnection().remoteObjectProxyWithErrorHandler(errorHandler) as? EngineXPCServiceProtocol
    }

    // Не `private` — `ping()` в `EngineXPCClient.swift` фиксирует текущее соединение ДО
    // круговой отправки, чтобы `markHandshakeVerified(for:)` могло сверить его с тем, что
    // осталось текущим к моменту успешного ответа (см. заголовок `handshakeVerifiedConnection`).
    func currentConnection() -> NSXPCConnection {
        return locked {
            if let connection { return connection }
            let fresh = makeConnection()
            fresh.remoteObjectInterface = NSXPCInterface(with: EngineXPCServiceProtocol.self)
            fresh.exportedInterface = NSXPCInterface(with: EngineXPCClientProtocol.self)
            fresh.exportedObject = ProgressReceiver { [weak self] data in self?.deliverProgress(data) }
            fresh.interruptionHandler = { [weak self] in self?.connectionDied(matching: fresh, crashed: true) }
            fresh.invalidationHandler = { [weak self] in self?.connectionDied(matching: fresh, crashed: false) }
            fresh.resume()
            connection = fresh
            return fresh
        }
    }

    /// К29/К52: `interruptionHandler` (сервис упал) — каждая живая задача получает
    /// `serviceCrashed` ровно один раз. `invalidationHandler` (соединение недействительно
    /// без восстановления) — `serviceUnavailable`. Соединение помечается мёртвым в обоих
    /// случаях — следующий запрос вызовет `makeConnection()` заново (К30).
    private func connectionDied(matching died: NSXPCConnection, crashed: Bool) {
        let affected: [PendingJob] = locked {
            guard connection === died else { return [] }
            connection = nil
            handshakeVerifiedConnection = nil
            let values = Array(jobs.values)
            jobs.removeAll()
            return values
        }
        if crashed {
            // Возврат РП по MEE-431 (09:40 UTC): обрыв (interruption) сам по себе не делает
            // NSXPCConnection недействительным — без явного `invalidate()` объект вправе САМ
            // попытаться поднять сервис заново поверх ЭТОГО ЖЕ соединения. Дизайн клиента
            // (заголовок EngineXPCClient.swift, К30) хочет ленивое ПЕРЕСОЗДАНИЕ через
            // `makeConnection()` на следующий запрос, а не скрытый повторный подъём в обход
            // этого пути; `invalidate()` на уже недействительном соединении — безопасный
            // no-op (документировано Foundation), так что вызов не по гонке не вредит.
            died.invalidate()
        }
        for job in affected {
            job.resolve(.failure(
                crashed ? TranscriptionServiceError.serviceCrashed
                        : TranscriptionServiceError.serviceUnavailable(message: "соединение недействительно")
            ))
        }
    }

    private func deliverProgress(_ data: Data) {
        guard let message = try? EngineWire.decode(EngineProgressMessage.self, from: data) else { return }
        let job: PendingJob? = locked { jobs[message.jobId] }
        guard let job else { return }   // К40(iii): запоздалый/чужой кадр — молча отброшен
        job.touch(self.clock())
        job.progress?(TranscriptionProgress(
            stage: Self.stageName(message.progress), fraction: Self.fraction(message.progress)
        ))
    }

    private static func stageName(_ progress: EngineProgress) -> String {
        switch progress {
        case .started(let stage), .finished(let stage): return stage.rawValue
        case .advanced(let stage, _): return stage.rawValue
        }
    }

    private static func fraction(_ progress: EngineProgress) -> Double {
        if case .advanced(_, let fraction) = progress { return fraction }
        return 0
    }

    // MARK: - Круговой обмен (кадр → EngineReply), таймаут, отмена

    /// К25: превышение размера ловится ДО обращения к транспорту — счётчик отправок
    /// фейка-транспорта не растёт. К38: сторож — реальный опрос малым интервалом,
    /// сравнивающий инжектируемое «сейчас» с моментом последней активности; тест продвигает
    /// часы мгновенно, опрос замечает это на ближайшем тике. К27/К28: отмена `Task`
    /// отправляет кадр `.cancel(jobId)` и резолвит немедленно, не дожидаясь ответа.
    func roundTrip(
        _ request: EngineRequest, timeoutSeconds: Int,
        progress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> EngineReply {
        try await requireProtocolHandshake(skipFor: request)
        let requestData = try encode(request)
        let jobId = Self.jobId(of: request)
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EngineReply, Error>) in
                    let job = PendingJob(continuation: continuation, progress: progress, startedAt: self.clock())
                    locked { jobs[jobId] = job }
                    // Возврат РП по MEE-431 (09:40 UTC), инв. 12: `onCancel` вправе сработать
                    // РАНЬШЕ этой регистрации — Swift зовёт его немедленно, если `Task` уже был
                    // отменён к моменту старта `withTaskCancellationHandler`, конкурентно с
                    // `operation`. В этот момент `jobs[jobId]` ещё нет, `onCancel`-овский
                    // `removeValue` находит `nil` и молча ничего не делает — отмена терялась
                    // бы, запрос всё равно ушёл бы на транспорт, а продолжение ждало бы ответа
                    // вечно. Проверка здесь, сразу после регистрации, подхватывает именно этот
                    // случай; `finish` — та же точка синхронизации (`removeValue` под замком),
                    // что и у `onCancel`, так что при одновременном срабатывании обоих путей
                    // ровно один получит задачу из словаря, другой — no-op.
                    guard !Task.isCancelled else {
                        finish(jobId: jobId, with: .failure(TranscriptionServiceError.cancelled))
                        return
                    }
                    startWatchdog(jobId: jobId, job: job, timeoutSeconds: timeoutSeconds)
                    dispatch(requestData, jobId: jobId)
                }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.sendCancelFrame(for: jobId)
                let job: PendingJob? = self.locked { self.jobs.removeValue(forKey: jobId) }
                job?.resolve(.failure(TranscriptionServiceError.cancelled))
            }
        )
    }

    private func encode(_ request: EngineRequest) throws -> Data {
        let data: Data
        do {
            data = try EngineWire.encode(request)
        } catch {
            throw TranscriptionServiceError.invalidRequest(message: "encoding: \(error)")
        }
        guard data.count <= EngineWire.maxMessageBytes else {
            throw TranscriptionServiceError.messageTooLarge(bytes: data.count)
        }
        return data
    }

    private func dispatch(_ requestData: Data, jobId: EngineJobId) {
        guard let proxy = serviceProxy(errorHandler: { [weak self] error in
            self?.complete(jobId: jobId, replyData: nil, error: error)
        }) else {
            finish(jobId: jobId, with: .failure(
                TranscriptionServiceError.serviceUnavailable(message: "прокси сервиса недоступен")
            ))
            return
        }
        proxy.send(requestData) { [weak self] replyData, error in
            self?.complete(jobId: jobId, replyData: replyData, error: error)
        }
    }

    /// К35: «оба заданы» и «оба пусты» — одно и то же нарушение протокола ответа, до
    /// разбора причины отдельно (обычный отказ транспорта или NSXPCConnection всегда несёт
    /// РОВНО одно из двух — эта проверка ловит только испорченный ответ, не штатный путь).
    private func complete(jobId: EngineJobId, replyData: Data?, error: Error?) {
        guard error == nil || replyData == nil else {
            let message = "нарушение протокола ответа: получены и данные, и ошибка одновременно"
            finish(jobId: jobId, with: .failure(TranscriptionServiceError.serviceUnavailable(message: message)))
            return
        }
        if let error {
            finish(jobId: jobId, with: .failure(map(nsError: error as NSError)))
            return
        }
        guard let replyData else {
            let message = "нарушение протокола ответа: ни данные, ни ошибка"
            finish(jobId: jobId, with: .failure(TranscriptionServiceError.serviceUnavailable(message: message)))
            return
        }
        do {
            let reply = try EngineWire.decode(EngineReply.self, from: replyData)
            finish(jobId: jobId, with: .success(reply))
        } catch let validationError as DomainValidationError {
            // §3.2: байты дошли целыми, форма кадра разобрана — невалиден РАЗОБРАННЫЙ
            // домен-объект внутри него (например `Transcript` с нарушенным инвариантом).
            // Это отказ движка, вернувшего плохой результат, а не транспорта — код
            // «invalidResult» дословно совпадает с именем случая `EngineError.invalidResult`
            // (`engineErrorCode`), которым размечен тот же исход, когда сервис успевает
            // заметить его сам и прислать `.failed(jobId, .invalidResult(...))`.
            finish(jobId: jobId, with: .failure(
                TranscriptionServiceError.engineFailure(code: "invalidResult", message: "\(validationError)")
            ))
        } catch {
            finish(jobId: jobId, with: .failure(
                TranscriptionServiceError.serviceUnavailable(message: "ответ не разобран: \(error)")
            ))
        }
    }

    private func finish(jobId: EngineJobId, with result: Result<EngineReply, Error>) {
        let job: PendingJob? = locked { jobs.removeValue(forKey: jobId) }
        job?.resolve(result)
    }

    /// Возврат РП по MEE-431 (09:40 UTC): не через `serviceProxy`/`currentConnection()` —
    /// те лениво ПОДНИМАЮТ соединение, если текущего уже нет. Если оно мертво (сервис упал,
    /// `connectionDied` уже обнулил `connection` и резолвил эту же задачу `serviceCrashed`),
    /// отправлять кадр `cancel` некому и незачем — только чтения существующего соединения,
    /// без побочного создания нового ради одного бесполезного кадра.
    private func sendCancelFrame(for jobId: EngineJobId) {
        guard let data = try? EngineWire.encode(EngineRequest.cancel(jobId)) else { return }
        guard let existing: NSXPCConnection = locked({ connection }) else { return }
        guard let proxy = existing.remoteObjectProxyWithErrorHandler({ _ in }) as? EngineXPCServiceProtocol else {
            return
        }
        proxy.send(data) { _, _ in }
    }

    private func startWatchdog(jobId: EngineJobId, job: PendingJob, timeoutSeconds: Int) {
        Task { [weak self] in
            guard let self else { return }
            while true {
                try? await Task.sleep(nanoseconds: Self.watchdogPollNanoseconds)
                if Task.isCancelled { return }
                let stillPending: Bool = self.locked { self.jobs[jobId] != nil }
                guard stillPending else { return }
                guard job.elapsedSeconds(since: self.clock()) >= Double(timeoutSeconds) else { continue }
                self.finish(jobId: jobId, with: .failure(TranscriptionServiceError.timedOut(seconds: timeoutSeconds)))
                return
            }
        }
    }

    private static func jobId(of request: EngineRequest) -> EngineJobId {
        switch request {
        case .transcribe(let id, _), .diarize(let id, _), .embed(let id, _),
             .postProcess(let id, _), .cancel(let id):
            return id
        case .ping:
            return EngineJobId(rawValue: UUID())
        }
    }

    // MARK: - Рукопожатие версии протокола (К21, К31)

    /// К21: несовпадение версии на `pong` — ни один рабочий запрос дальше не уходит.
    /// Проверяется один раз на соединение (кэш сбрасывается пересозданием соединения в
    /// `connectionDied`), сам `ping` рукопожатие не проверяет — он им и является.
    private func requireProtocolHandshake(skipFor request: EngineRequest) async throws {
        guard case .ping = request else {
            try await handshakeGate()
            return
        }
    }

    private func handshakeGate() async throws {
        guard !handshakeAlreadyVerified() else { return }
        // Тот же приём, что явный `ping()` (EngineXPCClient.swift): соединение фиксируется
        // ДО отправки, чтобы пометить верным именно ЕГО, а не то, что стало текущим позже.
        let connectionAtStart = currentConnection()
        let reply = try await roundTrip(.ping, timeoutSeconds: Self.pingTimeoutSeconds, progress: nil)
        guard case .pong(_, let serviceProtocolVersion) = reply else {
            throw TranscriptionServiceError.serviceUnavailable(message: "неожиданный ответ на рукопожатие: \(reply)")
        }
        try requireMatchingProtocolVersion(serviceProtocolVersion: serviceProtocolVersion)
        markHandshakeVerified(for: connectionAtStart)
    }

    private func handshakeAlreadyVerified() -> Bool {
        locked {
            guard let connection, let handshakeVerifiedConnection else { return false }
            return ObjectIdentifier(connection) == handshakeVerifiedConnection
        }
    }

    /// Не `private` — вызывается и явным `ping()` из `EngineXPCClient.swift`. Пишет, только
    /// если `verified` всё ещё ТЕКУЩЕЕ соединение — если оно уже сменилось (гонка с
    /// `connectionDied` между отправкой и этим успешным ответом), запись — no-op: новое
    /// соединение своё рукопожатие ещё не проходило, и молчаливо помечать его чужим было бы
    /// именно той гонкой, которую правит `handshakeVerifiedConnection`.
    func markHandshakeVerified(for verified: NSXPCConnection) {
        locked {
            guard connection === verified else { return }
            handshakeVerifiedConnection = ObjectIdentifier(verified)
        }
    }

    func requireMatchingProtocolVersion(serviceProtocolVersion: Int) throws {
        guard serviceProtocolVersion == EngineWire.protocolVersion else {
            throw TranscriptionServiceError.protocolVersionMismatch(
                client: EngineWire.protocolVersion, service: serviceProtocolVersion
            )
        }
    }
}
