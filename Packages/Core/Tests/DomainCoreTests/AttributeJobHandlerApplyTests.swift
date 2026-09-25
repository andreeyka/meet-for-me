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
            words: [try AttributeFixture.word("тишина", start: 500, end: 600)], start: 500, end: 1_000
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

    /// Правка приёмки РП (PR #136, 03:15 UTC): C-015 не гарантирует уникальность `wordIndex`
    /// внутри `textCorrections` одного сегмента — `run` не должен падать процессом, а не
    /// только не бросать `Error`. Правило реализации — последняя по порядку правка побеждает.
    func test_k38_duplicateWordIndexCorrectionsLastWinsWithoutCrashing() async throws {
        let harness = AttributeHarness()
        let words = [try AttributeFixture.word("привет"), try AttributeFixture.word("мир")]
        let segment = try AttributeFixture.segment(words: words)
        let transcript = try AttributeFixture.transcript(segments: [segment])
        let transcriptId = try await harness.seedTranscript(transcript)
        let rows = try await harness.transcripts.segments(transcriptId: transcriptId)
        let segmentId = rows[0].id
        let first = TextCorrection(
            segmentId: segmentId, wordIndex: 1, original: "мир", replacement: "Пётр",
            personId: UUID(), similarity: 0.8
        )
        let second = TextCorrection(
            segmentId: segmentId, wordIndex: 1, original: "мир", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )
        harness.port.forcedResult = AttributionResult(
            transcriptId: transcriptId, assignments: [], segmentUpdates: [],
            textCorrections: [first, second], profileUpdates: []
        )

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        XCTAssertEqual(outcome, .success, "две правки одного wordIndex не роняют обработчик")
        let updatedRows = try await harness.transcripts.segments(transcriptId: transcriptId)
        XCTAssertEqual(updatedRows[0].segment.text, "привет Иван", "последняя по порядку правка побеждает")
    }

    /// Правка приёмки РП (PR #136, 03:15 UTC): правка на сегмент, которого уже нет среди
    /// строк транскрипта, пропускается молча — не уходит `applyTextCorrections` с `text = ""`.
    func test_k38_correctionForMissingSegmentSkippedSilently() async throws {
        let harness = AttributeHarness()
        let words = [try AttributeFixture.word("привет"), try AttributeFixture.word("мир")]
        let segment = try AttributeFixture.segment(words: words)
        let transcript = try AttributeFixture.transcript(segments: [segment])
        let transcriptId = try await harness.seedTranscript(transcript)
        let rows = try await harness.transcripts.segments(transcriptId: transcriptId)
        let existingSegmentId = rows[0].id
        let missingSegmentId = existingSegmentId + 999
        let validCorrection = TextCorrection(
            segmentId: existingSegmentId, wordIndex: 1, original: "мир", replacement: "Иван",
            personId: UUID(), similarity: 0.9
        )
        let danglingCorrection = TextCorrection(
            segmentId: missingSegmentId, wordIndex: 0, original: "x", replacement: "y",
            personId: UUID(), similarity: 0.9
        )
        harness.port.forcedResult = AttributionResult(
            transcriptId: transcriptId, assignments: [], segmentUpdates: [],
            textCorrections: [validCorrection, danglingCorrection], profileUpdates: []
        )

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        XCTAssertEqual(outcome, .success)
        let calls = harness.log.calls(port: "TranscriptRepository")
            .filter { $0.method.hasPrefix("applyTextCorrections") }
        XCTAssertEqual(calls.count, 1, "пропавший сегмент не вызывает applyTextCorrections вовсе")
        let updatedRows = try await harness.transcripts.segments(transcriptId: transcriptId)
        XCTAssertEqual(updatedRows[0].segment.text, "привет Иван")
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

    /// Необязательный пункт приёмки РП (PR #136, 03:15 UTC): порядок применения —
    /// `updateAttribution` → `upsert` → `applyTextCorrections`, тем же порядком, что §7
    /// перечисляет применение результата.
    func test_k39_appliesInOrderUpdateAttributionThenUpsertThenApplyTextCorrections() async throws {
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
        let correction = TextCorrection(
            segmentId: rows[0].id, wordIndex: 0, original: "hi", replacement: "hello",
            personId: UUID(), similarity: 0.9
        )
        harness.port.forcedResult = AttributionResult(
            transcriptId: transcriptId, assignments: [], segmentUpdates: [update],
            textCorrections: [correction], profileUpdates: [profileUpdate]
        )

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(harness.log.happened(
            "TranscriptRepository.updateAttribution(_:)", before: "SpeakerProfileRepository.upsert(_:)"
        ))
        XCTAssertTrue(harness.log.happened(
            "SpeakerProfileRepository.upsert(_:)",
            before: "TranscriptRepository.applyTextCorrections(segmentId:text:corrections:)"
        ))
    }
}
