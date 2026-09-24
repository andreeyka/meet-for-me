//  К15 (половина Linux), К40(i) — C-011 §0 (представимость чисел провода), C-012 §3
//  (кадр прогресса, не разобравшийся целиком). Байты собраны `PlistSurgery`: закодировать
//  валидное значение, заменить один числовой литерал на непредставимый, декодировать
//  напрямую `EngineWire.decode` — без транспорта и без `EngineXPCClient` (эта часть
//  критерия — чистый факт провода, macOS-половина того же критерия сюда не входит).

import XCTest
import DomainCore
import EngineKit

final class EngineWireMalformedFieldTests: XCTestCase {

    private func assertDataCorrupted<T: Decodable>(
        _ type: T.Type, _ data: Data, file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            _ = try EngineWire.decode(type, from: data)
            XCTFail("ожидался DecodingError.dataCorrupted", file: file, line: line)
        } catch DecodingError.dataCorrupted {
            // ожидаемо
        } catch {
            XCTFail("неверный тип ошибки: \(error)", file: file, line: line)
        }
    }

    // MARK: - К15: AudioRef.sampleRate/.channelCount/.offsetMs

    func test_k15_audioRefSampleRateUnrepresentable() throws {
        let ref = try AudioRef(recordingId: EngineFixtures.recordingId, channel: .mic,
                               fileURL: EngineFixtures.fileURL, sampleRate: 48_000,
                               channelCount: 2, offsetMs: 3_000)
        let data = try PlistSurgery.data(for: ref, replacing: "<integer>48000</integer>",
                                         with: "<integer>100000000000000000</integer>")
        assertDataCorrupted(AudioRef.self, data)
    }

    func test_k15_audioRefChannelCountUnrepresentable() throws {
        let ref = try AudioRef(recordingId: EngineFixtures.recordingId, channel: .mic,
                               fileURL: EngineFixtures.fileURL, sampleRate: 48_000,
                               channelCount: 2, offsetMs: 3_000)
        let data = try PlistSurgery.data(for: ref, replacing: "<integer>2</integer>",
                                         with: "<integer>100000000000000000</integer>")
        assertDataCorrupted(AudioRef.self, data)
    }

    func test_k15_audioRefOffsetMsUnrepresentable() throws {
        let ref = try AudioRef(recordingId: EngineFixtures.recordingId, channel: .mic,
                               fileURL: EngineFixtures.fileURL, sampleRate: 48_000,
                               channelCount: 2, offsetMs: 3_000)
        let data = try PlistSurgery.data(for: ref, replacing: "<integer>3000</integer>",
                                         with: "<integer>100000000000000000</integer>")
        assertDataCorrupted(AudioRef.self, data)
    }

    // MARK: - К15: AudioSlice.startMs/.endMs

    private func makeSlice() throws -> AudioSlice {
        let source = try AudioRef(recordingId: EngineFixtures.recordingId, channel: .mic,
                                  fileURL: EngineFixtures.fileURL, sampleRate: 16_000,
                                  channelCount: 1, offsetMs: 0)
        return try AudioSlice(source: source, startMs: 100, endMs: 900)
    }

    func test_k15_audioSliceStartMsUnrepresentable() throws {
        let data = try PlistSurgery.data(for: try makeSlice(), replacing: "<integer>100</integer>",
                                         with: "<integer>100000000000000000</integer>")
        assertDataCorrupted(AudioSlice.self, data)
    }

    func test_k15_audioSliceEndMsUnrepresentable() throws {
        let data = try PlistSurgery.data(for: try makeSlice(), replacing: "<integer>900</integer>",
                                         with: "<integer>100000000000000000</integer>")
        assertDataCorrupted(AudioSlice.self, data)
    }

    // MARK: - К15: DiarizationRequest.expectedSpeakers

    func test_k15_diarizationRequestExpectedSpeakersUnrepresentable() throws {
        let audio = try AudioRef(recordingId: EngineFixtures.recordingId, channel: .system,
                                 fileURL: EngineFixtures.fileURL, sampleRate: 16_000,
                                 channelCount: 1, offsetMs: 0)
        let request = try DiarizationRequest(
            audio: audio, expectedSpeakers: 4,
            segmentationModel: EngineFixtures.modelBundle(role: .diarization),
            embeddingModel: EngineFixtures.modelBundle(role: .embedding)
        )
        let data = try PlistSurgery.data(for: request, replacing: "<integer>4</integer>",
                                         with: "<integer>100000000000000000</integer>")
        assertDataCorrupted(DiarizationRequest.self, data)
    }

    // MARK: - К15: DiarizationResult.Turn.startMs/.endMs/.cluster

    private func makeTurn() throws -> DiarizationResult.Turn {
        try DiarizationResult.Turn(startMs: 10, endMs: 20, cluster: 3)
    }

    func test_k15_turnStartMsUnrepresentable() throws {
        let data = try PlistSurgery.data(for: try makeTurn(), replacing: "<integer>10</integer>",
                                         with: "<integer>100000000000000000</integer>")
        assertDataCorrupted(DiarizationResult.Turn.self, data)
    }

    func test_k15_turnEndMsUnrepresentable() throws {
        let data = try PlistSurgery.data(for: try makeTurn(), replacing: "<integer>20</integer>",
                                         with: "<integer>100000000000000000</integer>")
        assertDataCorrupted(DiarizationResult.Turn.self, data)
    }

    func test_k15_turnClusterUnrepresentable() throws {
        let data = try PlistSurgery.data(for: try makeTurn(), replacing: "<integer>3</integer>",
                                         with: "<integer>100000000000000000</integer>")
        assertDataCorrupted(DiarizationResult.Turn.self, data)
    }

    // MARK: - К15: EmbeddingResult.vector (поэлементно) / .dimension

    private func makeEmbeddingResult() throws -> EmbeddingResult {
        try EmbeddingResult(vector: [0.1, 0.25, 0.5], dimension: 7, modelVersion: "v1")
    }

    func test_k15_embeddingResultVectorElementUnrepresentable() throws {
        let data = try PlistSurgery.data(for: try makeEmbeddingResult(), replacing: "<real>0.25</real>",
                                         with: "<real>1e400</real>")
        assertDataCorrupted(EmbeddingResult.self, data)
    }

    func test_k15_embeddingResultDimensionUnrepresentable() throws {
        let data = try PlistSurgery.data(for: try makeEmbeddingResult(), replacing: "<integer>7</integer>",
                                         with: "<integer>100000000000000000</integer>")
        assertDataCorrupted(EmbeddingResult.self, data)
    }

    // MARK: - К40(i)

    /// Кадр прогресса, испорченный на проводе, — чистый факт провода: декодирование
    /// бросает, дальше кадр не попадает никуда.
    func test_k40i_corruptedProgressFrameFailsToDecode() throws {
        let message = EngineProgressMessage(
            jobId: EngineJobId(rawValue: UUID()), progress: .advanced(stage: .asr, fraction: 0.4)
        )
        let data = try PlistSurgery.data(for: message, replacing: "<real>0.4</real>", with: "<real>1e400</real>")
        assertDataCorrupted(EngineProgressMessage.self, data)
    }
}
