//  EngineXPCClientRecordingTests+AudioRef — MEE-480, C-012 v12 §1.1 и инв. 25, 26: `AudioRef`
//  из манифеста, обратный вектор v12 (`isFinalized == false`), `embed` берёт `.system`,
//  `.diarize` не отправляется.

import XCTest
import DomainCore
import DomainTestKit
import EngineKit
@testable import EngineXPCClient

extension EngineXPCClientRecordingTests {

    private func sentTranscriptionRequest(
        _ stand: Stand, file: StaticString = #filePath, line: UInt = #line
    ) -> TranscriptionRequest? {
        for case .transcribe(_, let request) in stand.workRequests { return request }
        XCTFail("транспорт не получил .transcribe: \(stand.workRequests)", file: file, line: line)
        return nil
    }

    // MARK: - Инв. 25: две дорожки — две `AudioRef`, в порядке манифеста

    func test_inv25_twoTrackManifestGivesTwoAudioRefsInManifestOrder() async throws {
        let stand = Stand()
        let recordingId = UUID()
        let record = try RecordingFixtures.record(recordingId: recordingId)
        stand.recordings.seed([record])

        _ = try await stand.fixture.client.transcribe(makeSpec(recordingId: recordingId)) { _ in }

        let request = try XCTUnwrap(sentTranscriptionRequest(stand))
        let manifest = record.manifest
        XCTAssertEqual(request.audio.count, 2)
        XCTAssertEqual(request.audio.map(\.channel), [.system, .mic])
        for (audio, track) in zip(request.audio, manifest.tracks) {
            assertAudioRef(audio, track: track, manifest: manifest, layout: stand.fixture.temporaryLayout.layout)
        }
    }

    /// Порядок берётся из манифеста, а не из канала: `[mic, system]` уходит как `[mic, system]`.
    func test_inv25_audioRefOrderFollowsManifestNotChannel() async throws {
        let stand = Stand()
        let recordingId = UUID()
        let record = try RecordingFixtures.record(
            recordingId: recordingId, tracks: [RecordingFixtures.micTrack(), RecordingFixtures.systemTrack()]
        )
        stand.recordings.seed([record])

        _ = try await stand.fixture.client.transcribe(makeSpec(recordingId: recordingId)) { _ in }

        let request = try XCTUnwrap(sentTranscriptionRequest(stand))
        XCTAssertEqual(request.audio.map(\.channel), [.mic, .system])
        for (audio, track) in zip(request.audio, record.manifest.tracks) {
            assertAudioRef(audio, track: track, manifest: record.manifest, layout: stand.fixture.temporaryLayout.layout)
        }
    }

    // MARK: - Обратный вектор v12: `.finalized` при `isFinalized == false` — запрос уходит

    func test_v12_finalizedWithUnfinalizedManifestSendsRequest() async throws {
        let stand = Stand()
        let recordingId = UUID()
        let record = try RecordingFixtures.record(recordingId: recordingId)
        XCTAssertFalse(record.manifest.isFinalized, "предпосылка вектора: манифест не финализирован")
        XCTAssertEqual(Set(record.manifest.tracks.map(\.format)), ["pcm-caf"], "предпосылка вектора: pcm-caf")
        stand.recordings.seed([record])

        do {
            _ = try await stand.fixture.client.transcribe(makeSpec(recordingId: recordingId)) { _ in }
        } catch TranscriptionServiceError.recordingNotReady(_, let message) {
            XCTFail("v12: isFinalized не читается, а получен recordingNotReady: \(message)")
        }

        let request = try XCTUnwrap(sentTranscriptionRequest(stand))
        for (audio, track) in zip(request.audio, record.manifest.tracks) {
            assertAudioRef(audio, track: track, manifest: record.manifest, layout: stand.fixture.temporaryLayout.layout)
        }
        XCTAssertEqual(stand.fixture.modelCatalog.beginUseSuccessCount, 1)
    }

    // MARK: - `embed` берёт `.system`

    func test_embedUsesSystemTrackWithInvariant25Fields() async throws {
        let stand = Stand(embeddingModelId: "emb-1")
        let recordingId = UUID()
        // Системная дорожка не первая — выбор идёт по каналу, а не по позиции.
        let record = try RecordingFixtures.record(
            recordingId: recordingId, tracks: [RecordingFixtures.micTrack(), RecordingFixtures.systemTrack()]
        )
        stand.recordings.seed([record])

        _ = try await stand.fixture.client.embed(recordingId: recordingId, startMs: 100, endMs: 900, profileId: "p1")

        var embedRequests: [EmbeddingRequest] = []
        for case .embed(_, let request) in stand.workRequests { embedRequests.append(request) }
        XCTAssertEqual(embedRequests.count, 1)
        let slice = try XCTUnwrap(embedRequests.first?.slice)
        XCTAssertEqual(slice.startMs, 100)
        XCTAssertEqual(slice.endMs, 900)
        let systemTrack = try XCTUnwrap(record.manifest.tracks.first { $0.channel == .system })
        assertAudioRef(slice.source, track: systemTrack, manifest: record.manifest,
                       layout: stand.fixture.temporaryLayout.layout)
    }

    // MARK: - Инв. 26: `.diarize` не отправляется

    func test_inv26_diarizeRequestedSendsOnlyOneTranscribe() async throws {
        let stand = Stand()
        let catalog = stand.fixture.modelCatalog
        catalog.setCatalog([
            xpcTestDescriptor(id: "asr-1"),
            xpcTestDescriptor(id: "diar-1", role: .diarization),
            xpcTestDescriptor(id: "emb-1", role: .embedding)
        ])
        for id in ["asr-1", "diar-1", "emb-1"] { catalog.setState(.downloaded, forId: id, version: "1.0.0") }
        catalog.setProfiles([TranscriptionProfile(
            id: "p1", displayName: "p1", language: "ru", asrModelId: "asr-1", vadModelId: nil,
            diarizationModelId: "diar-1", embeddingModelId: "emb-1",
            diarization: DiarizationParameters(expectedSpeakers: nil, clusteringThreshold: 0.5, minSegmentMs: 500),
            isBuiltIn: false
        )])
        let resolved = try await catalog.resolve(profileId: "p1")
        XCTAssertNotNil(resolved.diarization, "предпосылка вектора: профиль называет диаризацию")
        XCTAssertNotNil(resolved.embedding, "предпосылка вектора: профиль называет эмбеддинги")
        let recordingId = UUID()
        stand.recordings.seed([try RecordingFixtures.record(recordingId: recordingId)])

        _ = try await stand.fixture.client.transcribe(makeSpec(recordingId: recordingId, diarize: true)) { _ in }

        let requests = stand.workRequests
        XCTAssertEqual(requests.count, 1, "\(requests)")
        var transcribeCount = 0
        var diarizeCount = 0
        for request in requests {
            switch request {
            case .transcribe: transcribeCount += 1
            case .diarize: diarizeCount += 1
            default: break
            }
        }
        XCTAssertEqual(transcribeCount, 1)
        XCTAssertEqual(diarizeCount, 0)
    }
}
