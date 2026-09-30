//  ClusterAssignmentTests — MEE-501 (Z3а): критерии 1–4, C-011 инвариант 18.

import DomainCore
import DomainTestKit
import XCTest
@testable import GigaAM

final class ClusterAssignmentTests: XCTestCase {

    private func draft(_ startMs: Int, _ endMs: Int, _ channel: RecordingManifest.Channel, _ text: String)
        -> SegmentDraft {
        SegmentDraft(
            startMs: startMs, endMs: endMs, channel: channel,
            words: [WordDraft(startMs: startMs, endMs: endMs, text: text)]
        )
    }

    // Критерий 1
    func testContentfulSystemGetsClusterZeroOthersNil() throws {
        let result = try ClusterAssignment.assign([
            draft(0, 1_000, .system, "раз"),
            draft(1_500, 3_000, .system, "два"),
            draft(3_500, 4_000, .system, "  "),
            draft(500, 900, .mic, "микрофон")
        ])
        XCTAssertEqual(result.clusters, [0, 0, nil, nil])
        XCTAssertEqual(result.speakers, [
            try Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 2_500)
        ])
    }

    // Критерий 2
    func testMicOnlyGivesNoSpeakers() throws {
        let result = try ClusterAssignment.assign([draft(0, 1_000, .mic, "раз"), draft(2_000, 3_000, .mic, "два")])
        XCTAssertEqual(result.clusters, [nil, nil])
        XCTAssertEqual(result.speakers, [])
    }

    func testBlankSystemOnlyGivesNoSpeakers() throws {
        let result = try ClusterAssignment.assign([draft(0, 1_000, .system, " ")])
        XCTAssertEqual(result.clusters, [nil])
        XCTAssertEqual(result.speakers, [])
    }

    // Критерий 3
    func testEmptyGivesNoSpeakers() throws {
        let result = try ClusterAssignment.assign([])
        XCTAssertEqual(result.clusters, [])
        XCTAssertEqual(result.speakers, [])
    }

    // Критерий 4
    func testResultPassesTranscriptInit() throws {
        let drafts = [
            draft(0, 1_000, .system, "раз"), draft(500, 900, .mic, "микрофон"), draft(1_500, 3_000, .system, "два")
        ]
        let result = try ClusterAssignment.assign(drafts)
        let segments = try zip(drafts, result.clusters).map {
            try $0.makeSegment(cluster: $1, wantWordTimestamps: true)
        }
        XCTAssertNoThrow(try Transcript(
            recordingId: UUID(), language: "ru", engine: "gigaam-sherpa-onnx", modelVersion: "3.0.0",
            createdAt: Date(timeIntervalSince1970: 0), segments: segments, speakers: result.speakers
        ))
    }

    // Фикстура DomainTestKit
    func testFixtureShapeMatchesInvariant18() throws {
        let fixture = TranscriptFixtures.systemChannelWithoutDiarization
        XCTAssertNoThrow(try fixture.validate())
        XCTAssertEqual(fixture.speakers.count, 1)
        XCTAssertNil(fixture.speakers.first?.embedding)
        XCTAssertNil(fixture.speakers.first?.embeddingModelVersion)
        for segment in fixture.segments {
            XCTAssertEqual(segment.speakerCluster, segment.channel == .system ? 0 : nil)
        }
        let total = fixture.segments.filter { $0.speakerCluster == 0 }.reduce(0) { $0 + $1.endMs - $1.startMs }
        XCTAssertEqual(fixture.speakers.first?.totalMs, total)
    }
}
