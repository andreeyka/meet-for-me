//  TestSupport — фикстуры MEE-438: настоящий `EngineXPCClient` (Mac, MEE-431) ПРОТИВ настоящей
//  диспетчерской логики сервиса (`EngineXPCRequestHandler`, `EngineXPCService`, тот же код,
//  что несёт продакшн `Services/TranscriptionEngineXPC`), через `NSXPCListener.anonymous()` в
//  одном процессе — не тестовый двойник (`TestEngineXPCService`, `EngineXPCClientTests/
//  TestSupport.swift`), а настоящий продакшн-код диспетчера, движки — `EngineKit/Fakes`.
//
//  `TestServiceConnectionDelegate`/`TestExportedRequestHandler` ниже — та же тонкая `NSObject`/
//  `@objc`-обвязка, что у продакшна (`Services/TranscriptionEngineXPC/Sources/
//  ServiceConnectionDelegate.swift`), продублированная здесь по тому же доводу, что и она сама:
//  `EngineXPCService` не может публично нести `NSObject`/`NSXPCConnection` (заголовок
//  `EngineXPCRequestHandler.swift`) — обвязка заводится в каждом потребителе отдельно,
//  диспетчерская ЛОГИКА при этом одна и та же, не дублируется.
//
//  `rawServiceProxy` — второй, более низкий уровень: соединение к тому же слушателю БЕЗ
//  `EngineXPCClient` поверх — нужен там, где проверяется сам сервис (§3.1 код 2, §3.2
//  decoding:/invariant:), а не отображение клиента (уже покрыто `EngineXPCClientTests`),
//  и там, где нужен `EngineRequest`, которого настоящий `EngineXPCClient` сегодня не строит
//  вовсе (`.postProcess`, `.diarize` — не в его публичном API, только у сервиса).
//
//  Импорт без `@testable` для типов провода (`EngineWire`, `DomainValidationError`) — тот же
//  приём, что `Packages/Core/Tests/EngineKitTests/EngineTestSupport.swift`: непредставимые
//  значения собираются только байтами (`PlistSurgery`), не внутренним путём приватных
//  `CodingKeys`/`EngineOwner`. `PlistSurgery`/фикстуры C-011 продублированы из той же
//  причины, что и в `EngineXPCClientTests/TestSupport.swift`: тестовые цели разных пакетов
//  друг друга не импортируют.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import EngineKit
@testable import EngineXPCClient
import EngineXPCService

/// Единственная обязанность — переадресовать `send(_:reply:)` протокола настоящему
/// `EngineXPCRequestHandler` (тот же код, что несёт продакшн `ExportedRequestHandler`,
/// `Services/TranscriptionEngineXPC/Sources/ServiceConnectionDelegate.swift`).
final class TestExportedRequestHandler: NSObject, EngineXPCServiceProtocol {
    let handler: EngineXPCRequestHandler

    init(handler: EngineXPCRequestHandler) {
        self.handler = handler
    }

    func send(_ requestData: Data, reply: @escaping (Data?, Error?) -> Void) {
        handler.handle(requestData, reply: reply)
    }
}

final class TestServiceConnectionDelegate: NSObject, NSXPCListenerDelegate {
    private let engines: EngineBundle
    private let serviceVersion: String

    init(engines: EngineBundle, serviceVersion: String) {
        self.engines = engines
        self.serviceVersion = serviceVersion
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: EngineXPCServiceProtocol.self)
        newConnection.remoteObjectInterface = NSXPCInterface(with: EngineXPCClientProtocol.self)
        let handler = EngineXPCRequestHandler(
            engines: engines, serviceVersion: serviceVersion,
            pushProgress: { [weak newConnection] data in
                guard let proxy = newConnection?.remoteObjectProxyWithErrorHandler({ _ in }) as? EngineXPCClientProtocol
                else { return }
                proxy.didReceiveProgress(data)
            }
        )
        let exportedObject = TestExportedRequestHandler(handler: handler)
        newConnection.exportedObject = exportedObject
        newConnection.interruptionHandler = { [weak exportedObject] in exportedObject?.handler.invalidate() }
        newConnection.invalidationHandler = { [weak exportedObject] in exportedObject?.handler.invalidate() }
        newConnection.resume()
        return true
    }
}

/// Слушатель + настоящая сторона сервиса + настоящий `EngineXPCClient`, все в одном процессе.
final class RealServiceFixture: NSObject {
    let transcription = FakeTranscriptionEngine()
    let diarization = FakeDiarizationEngine()
    let embedding = FakeEmbeddingEngine()
    let postProcessor = FakePostProcessor()
    let modelCatalog = FakeModelCatalogPort()
    let client: EngineXPCClient
    let serviceVersion: String

    private let listener: NSXPCListener
    private let delegate: TestServiceConnectionDelegate

    init(serviceVersion: String = "test-real-service", clock: @escaping @Sendable () -> Date = { Date() }) {
        let listener = NSXPCListener.anonymous()
        self.listener = listener
        self.serviceVersion = serviceVersion
        let bundle = EngineBundle(
            transcription: transcription, diarization: diarization,
            embedding: embedding, postProcessor: postProcessor
        )
        self.delegate = TestServiceConnectionDelegate(engines: bundle, serviceVersion: serviceVersion)
        self.client = EngineXPCClient(
            makeConnection: { NSXPCConnection(listenerEndpoint: listener.endpoint) },
            modelCatalog: modelCatalog, clock: clock
        )
        super.init()
        listener.delegate = delegate
        listener.resume()
    }

    /// Прокси `EngineXPCServiceProtocol` НАПРЯМУЮ, в обход `EngineXPCClient` — соединение
    /// живёт, пока вызывающая сторона держит возвращённый `NSXPCConnection` (`invalidate()`
    /// по завершении теста — тот же приём, что `defer` у прочих сырых соединений этого плана).
    /// Возврат РП по MEE-438 (11:50 UTC): раньше это соединение НЕ экспортировало
    /// `EngineXPCClientProtocol` вовсе — сервис (`pushProgress` в делегате) пытался толкнуть
    /// прогресс в несуществующий приёмник; сам круговой обмен `send(_:reply:)` от этого не
    /// виснет (прогресс и реплай — разные вызовы), но соединение было несимметричным
    /// продакшену без явной причины. Теперь экспортирует заглушку-приёмник (`onProgress`
    /// по умолчанию отбрасывает) — тот же приём, что настоящий `EngineXPCClient`
    /// (`ProgressReceiver`, `EngineXPCClient+Transport.swift`).
    func rawServiceProxy(
        errorHandler: @escaping (Error) -> Void = { _ in },
        onProgress: @escaping @Sendable (Data) -> Void = { _ in }
    ) -> (EngineXPCServiceProtocol, NSXPCConnection) {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: EngineXPCServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: EngineXPCClientProtocol.self)
        connection.exportedObject = TestRawProgressReceiver(onProgress: onProgress)
        connection.resume()
        // swiftlint:disable:next force_cast
        let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler) as! EngineXPCServiceProtocol
        return (proxy, connection)
    }
}

/// Заглушка `EngineXPCClientProtocol` для сырых соединений `rawServiceProxy` — тот же приём,
/// что `EngineXPCClient.ProgressReceiver` (`EngineXPCClient+Transport.swift`), нужен отдельный
/// `NSObject`, потому что тестовый код здесь `EngineXPCClient` не наследует.
final class TestRawProgressReceiver: NSObject, EngineXPCClientProtocol {
    private let onProgress: @Sendable (Data) -> Void
    init(onProgress: @escaping @Sendable (Data) -> Void) { self.onProgress = onProgress }
    func didReceiveProgress(_ progressData: Data) { onProgress(progressData) }
}

/// Резюмирует continuation ровно один раз — второй вызов молча игнорируется (тот же приём,
/// что `DeadlineOutcome`, `CaptureTests/DeadlineTestSupport.swift`).
private final class DeadlineOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(completed: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: completed)
    }
}

/// Ограничивает `operation` пределом `seconds` — продублировано из `CaptureTests/
/// DeadlineTestSupport.swift` (MEE-374, возврат РП 24.09 18:05: «новые сигналы `await*` этого
/// дерева обязаны падать `XCTFail`, а не висеть до сторожа CI»); тестовые цели разных пакетов
/// друг друга не импортируют, тот же довод, что у `PlistSurgery` в этом же файле. Возврат РП по
/// MEE-438 (11:50 UTC): круговой обмен через настоящий `NSXPCConnection` — тот случай, для
/// которого этот приём и заведён (гонка кооперативной отмены с реальным сервисом, не
/// симулированная фейком с управляемым временем).
func withDeadline(
    _ seconds: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ operation: @escaping @Sendable () async -> Void
) async {
    let operationTask = Task<Void, Never> { await operation() }
    let timeoutTask = Task<Void, Never> {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    defer {
        operationTask.cancel()
        timeoutTask.cancel()
    }
    let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let once = DeadlineOutcome(continuation)
        Task {
            await operationTask.value
            once.resume(completed: true)
        }
        Task {
            await timeoutTask.value
            once.resume(completed: false)
        }
    }
    if !completed {
        XCTFail("превышен предел ожидания \(seconds) с", file: file, line: line)
    }
}

/// Тот же приём, что `ProgressCollector` (`Core/EngineKitTests/EngineTestSupport.swift`), но
/// над `TranscriptionProgress` (DomainCore) — снятым с настоящего `EngineXPCClient.transcribe`,
/// а не с фейкового движка напрямую.
final class TranscriptionProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TranscriptionProgress] = []

    func append(_ item: TranscriptionProgress) {
        lock.lock(); items.append(item); lock.unlock()
    }

    var all: [TranscriptionProgress] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// `proxy.send(_:reply:)` как `async` — единственный способ ждать реплай-замыкание без
/// вложенных `XCTestExpectation` на каждый вызов.
func send(_ proxy: EngineXPCServiceProtocol, _ data: Data) async -> (Data?, NSError?) {
    await withCheckedContinuation { continuation in
        proxy.send(data) { replyData, error in
            continuation.resume(returning: (replyData, error as NSError?))
        }
    }
}

// MARK: - Фикстуры C-011 (продублировано из EngineKitTests/EngineTestSupport.swift)

enum ServiceFixtures {
    static let recordingId = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    static let fileURL = URL(fileURLWithPath: "/tmp/meet-for-me/audio-mic.m4a")

    static func audioRef(
        channel: RecordingManifest.Channel = .mic, offsetMs: Int = 0
    ) throws -> AudioRef {
        try AudioRef(
            recordingId: recordingId, channel: channel, fileURL: fileURL,
            sampleRate: 48_000, channelCount: 1, offsetMs: offsetMs
        )
    }

    static func modelBundle(role: ModelRole = .asr) -> ModelBundle {
        ModelBundle(
            modelId: "fake-\(role.rawValue)", version: "1.0", role: role,
            runtime: .onnx, directoryURL: URL(fileURLWithPath: "/tmp/meet-for-me/models/\(role.rawValue)")
        )
    }

    static func postProcessRequest(transcript: Transcript) throws -> PostProcessRequest {
        try PostProcessRequest(
            transcript: transcript, meetingTitle: nil, attendeeNames: [],
            agendaText: nil, profileId: "profile-1", model: nil
        )
    }

    static func diarizationRequest(expectedSpeakers: Int? = nil) throws -> DiarizationRequest {
        try DiarizationRequest(
            audio: try audioRef(channel: .system), expectedSpeakers: expectedSpeakers,
            segmentationModel: modelBundle(role: .diarization), embeddingModel: modelBundle(role: .embedding)
        )
    }
}

// MARK: - Фикстуры каталога моделей (продублировано из EngineXPCClientTests/TestSupport.swift)

func serviceTestDescriptor(id: String, role: ModelRole = .asr) -> ModelDescriptor {
    ModelDescriptor(
        id: id, version: "1.0.0", role: role, engine: "fake", runtime: .coreml,
        displayName: id, description: "", sizeBytes: 1, languages: ["ru"], files: [],
        quantization: nil, minChip: .m1, minRAMGB: 4, recommendedFor: []
    )
}

func serviceTestProfile(id: String, asrModelId: String, embeddingModelId: String? = nil) -> TranscriptionProfile {
    TranscriptionProfile(
        id: id, displayName: id, language: "ru", asrModelId: asrModelId, vadModelId: nil,
        diarizationModelId: nil, embeddingModelId: embeddingModelId,
        diarization: DiarizationParameters(expectedSpeakers: nil, clusteringThreshold: 0.5, minSegmentMs: 500),
        isBuiltIn: false
    )
}

/// Готовый профиль `"p1"` → модель `"asr-1"`, `.downloaded` — `resolve(profileId: "p1")` и
/// `beginUse` проходят без отказа (тот же приём, что `configureReadyProfile` в
/// `EngineXPCClientTests/TestSupport.swift`).
func configureReadyServiceProfile(_ port: FakeModelCatalogPort, embeddingModelId: String? = nil) {
    var descriptors = [serviceTestDescriptor(id: "asr-1")]
    if let embeddingModelId {
        descriptors.append(serviceTestDescriptor(id: embeddingModelId, role: .embedding))
        port.setState(.downloaded, forId: embeddingModelId, version: "1.0.0")
    }
    port.setCatalog(descriptors)
    port.setState(.downloaded, forId: "asr-1", version: "1.0.0")
    port.setProfiles([serviceTestProfile(id: "p1", asrModelId: "asr-1", embeddingModelId: embeddingModelId)])
}

enum PlistSurgeryError: Error {
    case targetNotFound(String)
    case notUTF8
}

/// Текстовая правка XML `PropertyList` — тот же приём, что `LoopbackTransportMalformedRequestTests`
/// (Core/EngineKitTests): `EngineWire.decode` разбирает XML и двоичный формат одинаково
/// (`PropertyListDecoder` формато-независим), формат XML взят только ради текстовой правки.
enum PlistSurgery {
    static func xml<T: Encodable>(for value: T) throws -> String {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw PlistSurgeryError.notUTF8
        }
        return text
    }

    static func replacing(_ text: String, _ target: String, with replacement: String) throws -> Data {
        guard text.contains(target) else { throw PlistSurgeryError.targetNotFound(target) }
        let mutated = text.replacingOccurrences(of: target, with: replacement)
        guard let data = mutated.data(using: .utf8) else { throw PlistSurgeryError.notUTF8 }
        return data
    }

    static func swapping(_ text: String, _ first: String, _ second: String) throws -> Data {
        guard text.contains(first), text.contains(second) else {
            throw PlistSurgeryError.targetNotFound("\(first) / \(second)")
        }
        let placeholder = "@@ENGINEXPCSERVICE_SWAP@@"
        let mutated = text
            .replacingOccurrences(of: first, with: placeholder)
            .replacingOccurrences(of: second, with: first)
            .replacingOccurrences(of: placeholder, with: second)
        guard let data = mutated.data(using: .utf8) else { throw PlistSurgeryError.notUTF8 }
        return data
    }
}
