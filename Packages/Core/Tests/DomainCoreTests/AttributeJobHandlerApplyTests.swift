//  AttributeJobHandlerApplyTests — К35, К36, К38, К39 перечня MEE-382, группы Л/М плана
//  MEE-396: пороги и применение `AttributionResult` (C-015 §7 v10), владелец: DEV-2.

import XCTest
import DomainCore
import DomainTestKit

final class AttributeJobHandlerApplyTests: XCTestCase {

    // MARK: - К35 (пороги — всегда slice1Defaults)

    func test_k35_attributeAlwaysUsesSlice1Defaults() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: transcriptId)

        _ = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        XCTAssertEqual(harness.port.lastAttributedThresholds, .slice1Defaults)
    }

    // MARK: - К36 (segmentUpdates → updateAttribution, один вызов)

    func test_k36_segmentUpdatesAppliedViaUpdateAttributionOnce() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        let rows = try await harness.transcripts.segments(transcriptId: transcriptId)
        let update = SegmentAttributionUpdate(
            segmentId: rows[0].id, personId: UUID(), speakerConfidence: 0.9, attributionSource: .micChannel
        )
        harness.port.forcedResult = AttributionResult(
            transcriptId: transcriptId, assignments: [], segmentUpdates: [update],
            textCorrections: [], profileUpdates: []
        )

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        XCTAssertEqual(outcome, .success)
        let calls = harness.log.calls(port: "TranscriptRepository").filter { $0.method == "updateAttribution(_:)" }
        XCTAssertEqual(calls.count, 1)
        let updatedRows = try await harness.transcripts.segments(transcriptId: transcriptId)
        XCTAssertEqual(updatedRows[0].personId, update.personId)
    }

    /// Пустой `segmentUpdates` — `updateAttribution` не вызван вовсе, не вызов с пустым массивом.
    func test_k36_emptySegmentUpdatesSkipsUpdateAttributionCall() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: transcriptId)

        _ = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        let calls = harness.log.calls(port: "TranscriptRepository").filter { $0.method == "updateAttribution(_:)" }
        XCTAssertEqual(calls.count, 0)
    }

    // MARK: - К38 (textCorrections — по одному вызову на сегмент с непустыми правками)

    func test_k38_applyTextCorrectionsCalledOncePerSegmentWithCorrections() async throws {
        let harness = AttributeHarness()
        let words = [try AttributeFixture.word("привет"), try AttributeFixture.word("мир")]
        let corrected = try AttributeFixture.segment(words: words, start: 0, end: 500)
        let uncorrected = try AttributeFixture.segment(
            words: [try AttributeFixture.word("тишина")], start: 500, end: 1_000
        )
        let transcript = try AttributeFixture.transcript(segments: [corrected, uncorrected])
        let transcriptId = try await harness.seedTranscript(transcript)
        let rows = try await harness.transcripts.segments(transcriptId: transcriptId)
        let correctedSegmentId = rows[0].id
        let correction = TextCorrection(
            segmentId: correctedSegmentId, wordIndex: 1, original: "мир", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )
        harness.port.forcedResult = AttributionResult(
            transcriptId: transcriptId, assignments: [], segmentUpdates: [],
            textCorrections: [correction], profileUpdates: []
        )

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        XCTAssertEqual(outcome, .success)
        let calls = harness.log.calls(port: "TranscriptRepository")
            .filter { $0.method.hasPrefix("applyTextCorrections") }
        XCTAssertEqual(calls.count, 1, "один вызов на сегмент с правками, не на весь результат")
        let updatedRows = try await harness.transcripts.segments(transcriptId: transcriptId)
        let updatedSegment = try XCTUnwrap(updatedRows.first { $0.id == correctedSegmentId })
        XCTAssertEqual(updatedSegment.segment.text, "привет Иван", "text строит обработчик, заменяя слова")
        let untouchedSegment = try XCTUnwrap(updatedRows.first { $0.id != correctedSegmentId })
        XCTAssertEqual(untouchedSegment.segment.text, "тишина", "сегмент без правок не тронут")
    }

    // MARK: - К39 (успешное применение — .success)

    func test_k39_successOnCleanApplication() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        let rows = try await harness.transcripts.segments(transcriptId: transcriptId)
        let update = SegmentAttributionUpdate(
            segmentId: rows[0].id, personId: UUID(), speakerConfidence: 0.9, attributionSource: .micChannel
        )
        let profileUpdate = SpeakerProfileUpdate(
            personId: UUID(), embedding: [0.1, 0.2], modelVersion: "v1", sampleCount: 1
        )
        harness.port.forcedResult = AttributionResult(
            transcriptId: transcriptId, assignments: [], segmentUpdates: [update],
            textCorrections: [], profileUpdates: [profileUpdate]
        )

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        XCTAssertEqual(outcome, .success)
        let storedProfile = try await harness.speakerProfiles.profile(
            personId: profileUpdate.personId, modelVersion: profileUpdate.modelVersion
        )
        XCTAssertEqual(storedProfile?.sampleCount, 1)
    }
}
