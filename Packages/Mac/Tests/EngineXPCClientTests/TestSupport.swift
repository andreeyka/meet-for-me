//  TestSupport — фикстуры плана MEE-389 (engine-xpc, часть 2): настоящий `NSXPCConnection`
//  между тестовым сервисом (`TestEngineXPCService`, движки — фейки `EngineKit.Fakes`) и
//  настоящим `EngineXPCClient`, через `NSXPCListener.anonymous()` в одном процессе.
//
//  Модуль: engine-xpc (тесты) · Владелец: DEV-2

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import EngineKit
@testable import EngineXPCClient

/// Тестовая сторона сервиса (`EngineXPCServiceProtocol`) — движки те же фейки C-011, что и
/// на Linux-половине этого плана (`LoopbackEngineTransport`), но диспетчер и приём/передача
/// байтов — свои: настоящий `NSXPCConnection`, не прямой вызов `receive(_:)`.
final class TestEngineXPCService: NSObject, EngineXPCServiceProtocol, @unchecked Sendable {

    private let transcription: TranscriptionEngine
    private let diarization: DiarizationEngine
    private let embedding: EmbeddingEngine
    private let postProcessor: PostProcessor

    private let lock = NSLock()
    private var jobs: [EngineJobId: Task<Void, Never>] = [:]
    private var sendCountValue = 0
    /// К22: `jobId` каждого разобранного рабочего/`cancel`-кадра, по порядку прихода.
    private var receivedJobIdsValue: [EngineJobId] = []

    /// Прокси клиента, которому пушить прогресс — назначается при подключении (`XPCFixture`).
    var progressTarget: EngineXPCClientProtocol?
    /// К21/К31/К33: подменяет `protocolVersion` в `pong`, либо форсирует код транспортного
    /// отказа вместо обычного разбора запроса.
    var protocolVersionOverride: Int?
    var forcedTransportFault: (code: Int, userInfo: [String: Any])?
    /// К35, К36: подменяет обычный разбор+диспетчеризацию произвольной парой (данные,
    /// ошибка) — единственный способ собрать «оба заданы»/«оба пусты»/испорченные байты,
    /// которые нормальный путь сервиса никогда сам не производит.
    var forcedRawResponse: (data: Data?, error: Error?)?
    /// К35 (чужой jobId/не тот род), К36 (`.failed` вместо ожидаемого рода) — сервис отвечает
    /// `EngineReply`, построенным из ЭТОЙ функции над реально разобранным `jobId` запроса,
    /// вместо результата настоящего движка (jobId нужен настоящий — его строит клиент сам,
    /// заранее не известен).
    var forcedReplyOverride: ((EngineJobId) -> EngineReply)?
    /// К38 (10с): `ping` без ответа — реплай-блок сознательно не зовётся.
    var swallowPing = false

    init(
        transcription: TranscriptionEngine = FakeTranscriptionEngine(),
        diarization: DiarizationEngine = FakeDiarizationEngine(),
        embedding: EmbeddingEngine = FakeEmbeddingEngine(),
        postProcessor: PostProcessor = FakePostProcessor()
    ) {
        self.transcription = transcription
        self.diarization = diarization
        self.embedding = embedding
        self.postProcessor = postProcessor
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var sendCount: Int { locked { sendCountValue } }
    var receivedJobIds: [EngineJobId] { locked { receivedJobIdsValue } }

    /// К23, К38(вектор сброса): пуш прогресса в обход настоящего движка — тест сам решает,
    /// когда и для какого `jobId` (в том числе после того, как настоящий ответ уже ушёл).
    func pushRawProgress(jobId: EngineJobId, progress: EngineProgress) {
        pushProgress(jobId: jobId, progress: progress)
    }

    func send(_ requestData: Data, reply: @escaping (Data?, Error?) -> Void) {
        locked { sendCountValue += 1 }
        if let fault = locked({ forcedTransportFault }) {
            reply(nil, Self.transportError(code: fault.code, userInfo: fault.userInfo))
            return
        }
        if let raw = locked({ forcedRawResponse }) {
            reply(raw.data, raw.error)
            return
        }
        let request: EngineRequest
        do {
            request = try EngineWire.decode(EngineRequest.self, from: requestData)
        } catch {
            let userInfo = [NSLocalizedDescriptionKey: "decoding: \(error)"]
            reply(nil, Self.transportError(code: EngineTransportFault.invalidRequest.rawValue, userInfo: userInfo))
            return
        }
        locked { receivedJobIdsValue.append(Self.jobId(of: request)) }
        if let overrideBuilder = locked({ forcedReplyOverride }) {
            respond(overrideBuilder(Self.jobId(of: request)), reply: reply)
            return
        }
        dispatch(request, reply: reply)
    }

    private func dispatch(_ request: EngineRequest, reply: @escaping (Data?, Error?) -> Void) {
        switch request {
        case .ping:
            // К38 (10с): «сервис не отвечает» — реплай-блок просто не зовём вовсе.
            guard !locked({ swallowPing }) else { return }
            let version = locked { protocolVersionOverride } ?? EngineWire.protocolVersion
            respond(.pong(serviceVersion: "test-service", protocolVersion: version), reply: reply)
        case .cancel(let jobId):
            let task: Task<Void, Never>? = locked { jobs[jobId] }
            task?.cancel()
            respond(.cancelled(jobId), reply: reply)
        case .transcribe(let jobId, let payload):
            start(jobId, reply: reply, operation: { [transcription] progress in
                try await transcription.transcribe(payload, progress: progress)
            }, makeReply: { .transcript(jobId, $0) })
        case .diarize(let jobId, let payload):
            start(jobId, reply: reply, operation: { [diarization] progress in
                try await diarization.diarize(payload, progress: progress)
            }, makeReply: { .diarization(jobId, $0) })
        case .embed(let jobId, let payload):
            start(jobId, reply: reply, operation: { [embedding] _ in
                try await embedding.embed(payload)
            }, makeReply: { .embedding(jobId, $0) })
        case .postProcess(let jobId, let payload):
            start(jobId, reply: reply, operation: { [postProcessor] progress in
                try await postProcessor.process(payload, progress: progress)
            }, makeReply: { .outputs(jobId, $0) })
        }
    }

    private func start<Value>(
        _ jobId: EngineJobId,
        reply: @escaping (Data?, Error?) -> Void,
        operation: @escaping (@Sendable @escaping (EngineProgress) -> Void) async throws -> Value,
        makeReply: @escaping (Value) -> EngineReply
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await operation { [weak self] progress in
                    self?.pushProgress(jobId: jobId, progress: progress)
                }
                self.finish(jobId, reply: reply, engineReply: makeReply(value))
            } catch EngineError.cancelled {
                self.finish(jobId, reply: reply, engineReply: .cancelled(jobId))
            } catch let error as EngineError {
                self.finish(jobId, reply: reply, engineReply: .failed(jobId, error))
            } catch {
                self.finish(jobId, reply: reply, engineReply: .failed(jobId, .runtimeFailure(message: "\(error)")))
            }
        }
        locked { jobs[jobId] = task }
    }

    private func finish(_ jobId: EngineJobId, reply: @escaping (Data?, Error?) -> Void, engineReply: EngineReply) {
        locked { jobs[jobId] = nil }
        respond(engineReply, reply: reply)
    }

    private func pushProgress(jobId: EngineJobId, progress: EngineProgress) {
        guard let target = locked({ progressTarget }) else { return }
        guard let data = try? EngineWire.encode(EngineProgressMessage(jobId: jobId, progress: progress)) else { return }
        target.didReceiveProgress(data)
    }

    private func respond(_ reply: EngineReply, reply replyBlock: @escaping (Data?, Error?) -> Void) {
        guard let data = try? EngineWire.encode(reply) else {
            let userInfo = [NSLocalizedDescriptionKey: "encoding failed"]
            replyBlock(nil, Self.transportError(code: EngineTransportFault.invalidRequest.rawValue, userInfo: userInfo))
            return
        }
        replyBlock(data, nil)
    }

    private static func transportError(code: Int, userInfo: [String: Any]) -> NSError {
        NSError(domain: EngineTransportFault.errorDomain, code: code, userInfo: userInfo)
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
}

/// Слушатель + сервис + настоящий клиент, все в одном процессе (`NSXPCListener.anonymous()`).
/// Приём соединений — через `NSXPCListenerDelegate`, а не замыкание: у `NSXPCListener` нет
/// свойства `newConnectionHandler`, только делегат.
final class XPCFixture: NSObject {
    let service: TestEngineXPCService
    let modelCatalog = FakeModelCatalogPort()
    let client: EngineXPCClient

    private let listener: NSXPCListener
    private let lock = NSLock()
    private var acceptedConnections: [NSXPCConnection] = []

    init(
        service: TestEngineXPCService = TestEngineXPCService(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        let listener = NSXPCListener.anonymous()
        self.listener = listener
        self.client = EngineXPCClient(
            makeConnection: { NSXPCConnection(listenerEndpoint: listener.endpoint) },
            modelCatalog: modelCatalog, clock: clock
        )
        super.init()
        listener.delegate = self
        listener.resume()
    }

    /// К29/К52(i): «сервис упал» с точки зрения клиента — обрыв ПРИНЯТОГО (серверного)
    /// конца соединения, а не собственного клиентского.
    func simulateServiceCrash() {
        lock.lock(); let connection = acceptedConnections.last; lock.unlock()
        connection?.invalidate()
    }
}

extension XPCFixture: NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: EngineXPCServiceProtocol.self)
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = NSXPCInterface(with: EngineXPCClientProtocol.self)
        newConnection.resume()
        service.progressTarget = newConnection.remoteObjectProxy as? EngineXPCClientProtocol
        lock.lock(); acceptedConnections.append(newConnection); lock.unlock()
        return true
    }
}

// MARK: - Построители фикстур каталога моделей (К46, К53)

func xpcTestDescriptor(id: String, role: ModelRole = .asr) -> ModelDescriptor {
    ModelDescriptor(
        id: id, version: "1.0.0", role: role, engine: "fake", runtime: .coreml,
        displayName: id, description: "", sizeBytes: 1, languages: ["ru"], files: [],
        quantization: nil, minChip: .m1, minRAMGB: 4, recommendedFor: []
    )
}

func xpcTestProfile(id: String, asrModelId: String, embeddingModelId: String? = nil) -> TranscriptionProfile {
    TranscriptionProfile(
        id: id, displayName: id, language: "ru", asrModelId: asrModelId, vadModelId: nil,
        diarizationModelId: nil, embeddingModelId: embeddingModelId,
        diarization: DiarizationParameters(expectedSpeakers: nil, clusteringThreshold: 0.5, minSegmentMs: 500),
        isBuiltIn: false
    )
}

/// Готовый профиль `"p1"` → модель `"asr-1"`, `.downloaded`, в заданном каталоге —
/// `resolve(profileId: "p1")` и `beginUse` проходят без отказа.
func configureReadyProfile(_ port: FakeModelCatalogPort, embeddingModelId: String? = nil) {
    var descriptors = [xpcTestDescriptor(id: "asr-1")]
    if let embeddingModelId {
        descriptors.append(xpcTestDescriptor(id: embeddingModelId, role: .embedding))
        port.setState(.downloaded, forId: embeddingModelId, version: "1.0.0")
    }
    port.setCatalog(descriptors)
    port.setState(.downloaded, forId: "asr-1", version: "1.0.0")
    port.setProfiles([xpcTestProfile(id: "p1", asrModelId: "asr-1", embeddingModelId: embeddingModelId)])
}
