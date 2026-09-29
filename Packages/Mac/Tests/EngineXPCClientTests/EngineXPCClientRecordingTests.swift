//  EngineXPCClientRecordingTests — MEE-480, C-012 v12 §1.1 и инварианты 24–26: запись из
//  `RecordingRepository`, дорожки из манифеста, `recordingNotReady`, отсутствие `.diarize`.
//  Настоящий `EngineXPCClient` поверх настоящего `NSXPCConnection` к тестовому сервису
//  (`TestEngineXPCService` — он же счётчик и журнал отправок транспорта),
//  `InMemoryRecordingRepository` и `TemporaryFileLayout` (`DomainTestKit`).

import XCTest
import DomainCore
import DomainTestKit
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientRecordingTests: XCTestCase {

    static let recordingCall = "RecordingRepository.recording(id:)"
    static let resolveCall = "ModelCatalogPort.resolve(profileId:)"
    static let beginUseCall = "ModelCatalogPort.beginUse(_:)"

    /// Клиент над общим журналом: репозиторий и каталог пишут в один `PortCallLog`.
    struct Stand {
        let log: PortCallLog
        let recordings: InMemoryRecordingRepository
        let fixture: XPCFixture

        init(embeddingModelId: String? = nil) {
            let log = PortCallLog()
            self.log = log
            self.recordings = InMemoryRecordingRepository(log: log)
            self.fixture = XPCFixture(recordings: recordings) { LoggingModelCatalog(base: $0, log: log) }
            configureReadyProfile(fixture.modelCatalog, embeddingModelId: embeddingModelId)
        }

        var workRequests: [EngineRequest] { fixture.service.receivedRequests }
    }

    func makeSpec(recordingId: UUID, diarize: Bool = false) -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: recordingId, profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: diarize
        )
    }

    /// Инв. 25 для одной дорожки: поля из манифеста и `Track`, путь формулой `AudioTrackRef`.
    func assertAudioRef(
        _ audio: AudioRef, track: RecordingManifest.Track, manifest: RecordingManifest, layout: FileLayout,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(audio.recordingId, manifest.recordingId, file: file, line: line)
        XCTAssertEqual(audio.channel, track.channel, file: file, line: line)
        XCTAssertEqual(audio.sampleRate, track.sampleRate, file: file, line: line)
        XCTAssertEqual(audio.channelCount, track.channelCount, file: file, line: line)
        XCTAssertEqual(
            audio.fileURL,
            layout.recordingDirectory(manifest.directoryName).appendingPathComponent(track.fileName),
            file: file, line: line
        )
        XCTAssertEqual(audio.offsetMs, 0, file: file, line: line)
    }

    // MARK: - Инв. 24: один вызов `recording(id:)`, раньше `resolve`

    func test_inv24_transcribeReadsRecordingOnceBeforeResolve() async throws {
        let stand = Stand()
        let recordingId = UUID()
        stand.recordings.seed([try RecordingFixtures.record(recordingId: recordingId)])

        _ = try await stand.fixture.client.transcribe(makeSpec(recordingId: recordingId)) { _ in }

        XCTAssertEqual(stand.log.calls(port: InMemoryRecordingRepository.portName).map(\.signature),
                       [Self.recordingCall])
        XCTAssertEqual(stand.log.calls(port: InMemoryRecordingRepository.portName).first?.arguments,
                       [recordingId.uuidString])
        XCTAssertTrue(stand.log.happened(Self.recordingCall, before: Self.resolveCall), "\(stand.log.signatures)")
    }

    func test_inv24_embedReadsRecordingOnceBeforeResolve() async throws {
        let stand = Stand(embeddingModelId: "emb-1")
        let recordingId = UUID()
        stand.recordings.seed([try RecordingFixtures.record(recordingId: recordingId)])

        _ = try await stand.fixture.client.embed(recordingId: recordingId, startMs: 0, endMs: 1000, profileId: "p1")

        XCTAssertEqual(stand.log.calls(port: InMemoryRecordingRepository.portName).map(\.signature),
                       [Self.recordingCall])
        XCTAssertTrue(stand.log.happened(Self.recordingCall, before: Self.resolveCall), "\(stand.log.signatures)")
    }
}
