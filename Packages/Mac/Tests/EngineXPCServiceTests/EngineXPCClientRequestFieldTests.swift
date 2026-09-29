//  EngineXPCClientRequestFieldTests — MEE-451, К15 направления «клиент → сервис» (сверка QA,
//  MEE-389 `bfbd0b51`, дыра 2): шесть полей (`AudioRef.sampleRate`/`.channelCount`/`.offsetMs`,
//  `AudioSlice.startMs`/`.endMs`, `DiarizationRequest.expectedSpeakers`) с непредставимым
//  значением байтами → настоящий диспетчер сервиса (`EngineXPCRequestHandler`) → настоящий
//  `EngineXPCClient` → `invalidRequest(message: "decoding: …")`.
//
//  Как вектор попадает на провод. Публичный API клиента непредставимого значения не
//  соберёт: throwing-init C-011 отвергает его раньше кодирования. Поэтому рабочий кадр,
//  уже отправленный клиентом, правится на стороне приёма — ДО передачи байтов
//  диспетчеру (тот же приём `PlistSurgery`, что и на Linux-половине К15). `ping` и
//  `cancel` проходят нетронутыми.
//
//  `DiarizationRequest` клиент не строит вовсе (в `TranscriptionServicePort` нет `diarize`) —
//  для этого поля рабочий кадр `transcribe` подменяется кадром `.diarize` с тем же `jobId`
//  и испорченным `expectedSpeakers`. Клиентская сторона пути та же самая: ответ на ЕГО
//  `jobId`, отображение кода 3 — его.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import EngineKit
@testable import EngineXPCClient
import EngineXPCService

final class EngineXPCClientRequestFieldTests: XCTestCase {

    private static let unrepresentable = "100000000000000000"

    private func makeSpec() -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    private func assertDecodingInvalidRequest(
        _ fixture: RequestSurgeryFixture, embed: Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            if embed {
                _ = try await fixture.client.embed(recordingId: UUID(), startMs: 100, endMs: 900, profileId: "p1")
            } else {
                _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            }
            XCTFail("ожидался invalidRequest", file: file, line: line)
        } catch TranscriptionServiceError.invalidRequest(let message) {
            XCTAssertTrue(message.hasPrefix("decoding: "), message, file: file, line: line)
        } catch {
            XCTFail("неверный исход: \(error)", file: file, line: line)
        }
        XCTAssertEqual(fixture.surgeryCount, 1, "правка обязана была попасть ровно в один рабочий кадр",
                       file: file, line: line)
        XCTAssertEqual(fixture.surgeryErrors, [], file: file, line: line)
    }

    /// Правка по ключу, а не по значению: `<key>K</key><integer>…</integer>` — значение
    /// меняется у первого вхождения ключа в тексте.
    private static func corruptingKey(_ key: String) -> @Sendable (EngineRequest, String) throws -> String {
        { _, xml in try PlistKeySurgery.replacingInteger(forKey: key, in: xml, with: unrepresentable) }
    }

    // MARK: - AudioRef (через transcribe)

    func test_k15_requestAudioRefSampleRateUnrepresentableGivesDecodingInvalidRequest() async throws {
        let fixture = RequestSurgeryFixture(surgery: Self.corruptingKey("sampleRate"))
        configureReadyServiceProfile(fixture.modelCatalog)
        await assertDecodingInvalidRequest(fixture, embed: false)
    }

    func test_k15_requestAudioRefChannelCountUnrepresentableGivesDecodingInvalidRequest() async throws {
        let fixture = RequestSurgeryFixture(surgery: Self.corruptingKey("channelCount"))
        configureReadyServiceProfile(fixture.modelCatalog)
        await assertDecodingInvalidRequest(fixture, embed: false)
    }

    func test_k15_requestAudioRefOffsetMsUnrepresentableGivesDecodingInvalidRequest() async throws {
        let fixture = RequestSurgeryFixture(surgery: Self.corruptingKey("offsetMs"))
        configureReadyServiceProfile(fixture.modelCatalog)
        await assertDecodingInvalidRequest(fixture, embed: false)
    }

    // MARK: - AudioSlice (через embed)

    func test_k15_requestAudioSliceStartMsUnrepresentableGivesDecodingInvalidRequest() async throws {
        let fixture = RequestSurgeryFixture(surgery: Self.corruptingKey("startMs"))
        configureReadyServiceProfile(fixture.modelCatalog, embeddingModelId: "emb-1")
        await assertDecodingInvalidRequest(fixture, embed: true)
    }

    func test_k15_requestAudioSliceEndMsUnrepresentableGivesDecodingInvalidRequest() async throws {
        let fixture = RequestSurgeryFixture(surgery: Self.corruptingKey("endMs"))
        configureReadyServiceProfile(fixture.modelCatalog, embeddingModelId: "emb-1")
        await assertDecodingInvalidRequest(fixture, embed: true)
    }

    // MARK: - DiarizationRequest.expectedSpeakers (кадр transcribe подменён кадром diarize)

    func test_k15_requestDiarizationExpectedSpeakersUnrepresentableGivesDecodingInvalidRequest() async throws {
        let fixture = RequestSurgeryFixture(surgery: { request, _ in
            guard case .transcribe(let jobId, _) = request else {
                throw PlistSurgeryError.targetNotFound("ожидался кадр transcribe, а пришёл \(request)")
            }
            let diarize = EngineRequest.diarize(jobId, try ServiceFixtures.diarizationRequest(expectedSpeakers: 4))
            return try PlistKeySurgery.replacingInteger(
                forKey: "expectedSpeakers", in: try PlistSurgery.xml(for: diarize), with: Self.unrepresentable
            )
        })
        configureReadyServiceProfile(fixture.modelCatalog)
        await assertDecodingInvalidRequest(fixture, embed: false)
    }
}

// MARK: - Фикстура: настоящий диспетчер сервиса с правкой входящего рабочего кадра

enum PlistKeySurgery {
    static func replacingInteger(forKey key: String, in xml: String, with value: String) throws -> String {
        let pattern = "<key>\(key)</key>\\s*<integer>[^<]*</integer>"
        guard let range = xml.range(of: pattern, options: .regularExpression) else {
            throw PlistSurgeryError.targetNotFound(key)
        }
        return xml.replacingCharacters(in: range, with: "<key>\(key)</key><integer>\(value)</integer>")
    }
}

final class RequestSurgeryFixture: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    typealias Surgery = @Sendable (EngineRequest, String) throws -> String

    let modelCatalog = FakeModelCatalogPort()
    /// MEE-480: раскладка, из которой клиент строит `AudioRef.fileURL` (C-012 v12 §1.1).
    let temporaryLayout = TemporaryFileLayout()
    let client: EngineXPCClient

    private let listener: NSXPCListener
    private let surgery: Surgery
    private let engines = EngineBundle(
        transcription: FakeTranscriptionEngine(), diarization: FakeDiarizationEngine(),
        embedding: FakeEmbeddingEngine(), postProcessor: FakePostProcessor()
    )
    private let lock = NSLock()
    private var surgeryCountValue = 0
    private var surgeryErrorsValue: [String] = []

    init(surgery: @escaping Surgery) {
        self.surgery = surgery
        let listener = NSXPCListener.anonymous()
        self.listener = listener
        self.client = EngineXPCClient(
            makeConnection: { NSXPCConnection(listenerEndpoint: listener.endpoint) },
            modelCatalog: modelCatalog, recordings: AnyIdFinalizedRecordingRepository(),
            fileLayout: temporaryLayout.layout
        )
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var surgeryCount: Int { lock.lock(); defer { lock.unlock() }; return surgeryCountValue }
    var surgeryErrors: [String] { lock.lock(); defer { lock.unlock() }; return surgeryErrorsValue }

    /// Рабочий кадр (`transcribe`/`embed`/`diarize`/`postProcess`) — в XML, правка, обратно в
    /// байты; `EngineWire.decode` читает XML и двоичный формат одинаково. `ping`/`cancel` —
    /// как есть.
    fileprivate func rewrite(_ data: Data) -> Data {
        guard let request = try? EngineWire.decode(EngineRequest.self, from: data) else { return data }
        switch request {
        case .ping, .cancel: return data
        default: break
        }
        do {
            let mutated = try surgery(request, try PlistSurgery.xml(for: request))
            lock.lock(); surgeryCountValue += 1; lock.unlock()
            return Data(mutated.utf8)
        } catch {
            lock.lock(); surgeryErrorsValue.append("\(error)"); lock.unlock()
            return data
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: EngineXPCServiceProtocol.self)
        newConnection.remoteObjectInterface = NSXPCInterface(with: EngineXPCClientProtocol.self)
        let handler = EngineXPCRequestHandler(engines: engines, serviceVersion: "surgery", pushProgress: { _ in })
        newConnection.exportedObject = SurgeryExportedHandler(handler: handler, owner: self)
        newConnection.resume()
        return true
    }
}

private final class SurgeryExportedHandler: NSObject, EngineXPCServiceProtocol {
    private let handler: EngineXPCRequestHandler
    private weak var owner: RequestSurgeryFixture?

    init(handler: EngineXPCRequestHandler, owner: RequestSurgeryFixture) {
        self.handler = handler
        self.owner = owner
    }

    func handle(_ requestData: Data, reply: @escaping (Data?, NSError?) -> Void) {
        handler.handle(owner?.rewrite(requestData) ?? requestData) { data, error in
            reply(data, error.map { $0 as NSError })
        }
    }
}
