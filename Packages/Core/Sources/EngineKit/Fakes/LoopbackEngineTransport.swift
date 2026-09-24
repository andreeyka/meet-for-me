//  LoopbackEngineTransport — C-012 v10 «Фейк для тестов»: транспорт без XPC. Разбирает
//  `EngineRequest`, отдаёт фейковым движкам C-011 (публичный инициализатор принимает их —
//  дословно по контракту), возвращает `EngineReply` тем же путём. Публичный API сверх этого
//  контракт не называет («Не специфицировано — на усмотрение реализации») — из явно
//  перечисленных возможностей эта часть (Core/Linux) покрывает кодирование, порядок
//  «прогресс → финальный ответ», отмену и наблюдаемую границу ответов (К48); имитацию
//  падения сервиса/выгрузки по простою эта часть не заводит — ни один критерий части 1 её
//  не требует, решение оставлено явным для части 2 (клиент, Core + Mac), где будет видно,
//  какая форма нужна вызывающей стороне.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения) — фейки
//
//  Инвариант 1: ровно один финальный `EngineReply` на `jobId` — каждая задача видит СВОЙ
//  единственный путь завершения (успех/`EngineError`/отмена), второй раз `finish` для того
//  же `jobId` не зовётся. Инвариант 6: `cancel(jobId)` неизвестного или уже завершённого —
//  успешный no-op: `jobs[jobId]` уже `nil`, отменять нечего, ответа не будет.

import DomainCore
import Foundation

public final class LoopbackEngineTransport: @unchecked Sendable {

    private let transcription: TranscriptionEngine
    private let diarization: DiarizationEngine
    private let embedding: EmbeddingEngine
    private let postProcessor: PostProcessor

    private let lock = NSLock()
    private var jobs: [EngineJobId: Task<Void, Never>] = [:]
    private var repliesSent: [EngineReply] = []
    private var progressSent: [EngineProgressMessage] = []

    public init(
        transcription: TranscriptionEngine, diarization: DiarizationEngine,
        embedding: EmbeddingEngine, postProcessor: PostProcessor
    ) {
        self.transcription = transcription
        self.diarization = diarization
        self.embedding = embedding
        self.postProcessor = postProcessor
    }

    // MARK: - Наблюдаемая граница (К48: ровно один финальный ответ на jobId)

    public var sentReplies: [EngineReply] {
        lock.lock(); defer { lock.unlock() }
        return repliesSent
    }

    public var sentProgress: [EngineProgressMessage] {
        lock.lock(); defer { lock.unlock() }
        return progressSent
    }

    // MARK: - «Служба» петли

    /// Байты запроса, будто пришедшие с провода — круг через `EngineWire` целиком.
    public func receive(_ requestData: Data) throws {
        receive(try EngineWire.decode(EngineRequest.self, from: requestData))
    }

    /// К26: тест заводит `EngineRequest` напрямую, минуя провод, — тем же диспетчером.
    public func receive(_ request: EngineRequest) {
        switch request {
        case .transcribe(let jobId, let payload):
            start(jobId, operation: { [transcription] progress in
                try await transcription.transcribe(payload, progress: progress)
            }, reply: { .transcript(jobId, $0) })
        case .diarize(let jobId, let payload):
            start(jobId, operation: { [diarization] progress in
                try await diarization.diarize(payload, progress: progress)
            }, reply: { .diarization(jobId, $0) })
        case .embed(let jobId, let payload):
            start(jobId, operation: { [embedding] _ in
                try await embedding.embed(payload)
            }, reply: { .embedding(jobId, $0) })
        case .postProcess(let jobId, let payload):
            start(jobId, operation: { [postProcessor] progress in
                try await postProcessor.process(payload, progress: progress)
            }, reply: { .outputs(jobId, $0) })
        case .cancel(let jobId):
            cancelIfLive(jobId)
        case .ping:
            recordReply(.pong(serviceVersion: "loopback", protocolVersion: EngineWire.protocolVersion))
        }
    }

    private func start<Value>(
        _ jobId: EngineJobId,
        operation: @escaping (@Sendable @escaping (EngineProgress) -> Void) async throws -> Value,
        reply: @escaping (Value) -> EngineReply
    ) {
        lock.lock()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await operation { progress in
                    self.recordProgress(EngineProgressMessage(jobId: jobId, progress: progress))
                }
                self.finish(jobId, with: reply(value))
            } catch EngineError.cancelled {
                self.finish(jobId, with: .cancelled(jobId))
            } catch let error as EngineError {
                self.finish(jobId, with: .failed(jobId, error))
            } catch {
                self.finish(jobId, with: .failed(jobId, .runtimeFailure(message: "\(error)")))
            }
        }
        jobs[jobId] = task
        lock.unlock()
    }

    /// «В той части, что проверяет провод» (шапка файла): каждый `EngineReply` уходит
    /// наблюдателю не как значение из памяти, а после `EngineWire.normalizingDates` →
    /// `encode` → `decode` — тем же кругом, каким он реально идёт по проводу. Круг бросает
    /// только на значении, уже нарушающем C-011/C-012 (К42 — на валидных фикстурах не бросает
    /// никогда), а такое значение сюда дойти не может: `operation` в `start` заворачивает
    /// нарушение в `EngineError.invalidResult` раньше, чем строится `EngineReply`.
    private func wired(_ reply: EngineReply) -> EngineReply {
        // swiftlint:disable:next force_try
        try! EngineWire.decode(EngineReply.self, from: EngineWire.encode(EngineWire.normalizingDates(reply)))
    }

    private func finish(_ jobId: EngineJobId, with reply: EngineReply) {
        let value = wired(reply)
        lock.lock()
        jobs[jobId] = nil
        repliesSent.append(value)
        lock.unlock()
    }

    /// Тот же круг для прогресса — без `normalizingDates`, у `EngineProgress` нет `Date`.
    private func recordProgress(_ message: EngineProgressMessage) {
        // swiftlint:disable:next force_try
        let value = try! EngineWire.decode(EngineProgressMessage.self, from: EngineWire.encode(message))
        lock.lock(); progressSent.append(value); lock.unlock()
    }

    private func recordReply(_ reply: EngineReply) {
        let value = wired(reply)
        lock.lock(); repliesSent.append(value); lock.unlock()
    }

    private func cancelIfLive(_ jobId: EngineJobId) {
        lock.lock()
        let task = jobs[jobId]
        lock.unlock()
        task?.cancel()
    }
}
