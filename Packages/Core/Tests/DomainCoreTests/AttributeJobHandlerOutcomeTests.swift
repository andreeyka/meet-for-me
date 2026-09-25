//  AttributeJobHandlerOutcomeTests — К40, К41, К42 перечня MEE-382, группа Н плана
//  MEE-396: отображение отказов в `JobOutcome` (C-015 §7 v10), владелец: DEV-2.

import XCTest
import DomainCore
import DomainTestKit

final class AttributeJobHandlerOutcomeTests: XCTestCase {

    // MARK: - К40 (все шесть AttributionError — permanentFailure, никогда retry)

    func test_k40_allSixAttributionErrorsMapToPermanentFailureNeverRetry() async throws {
        let cases: [AttributionError] = [
            .unknownTranscript(UUID()),
            .unknownCluster(1),
            .unknownPerson(UUID()),
            .embeddingModelMismatch(expected: "a", actual: "b"),
            .segmentIdsMismatch(expected: 1, actual: 2),
            .voiceProfilesDisabled
        ]
        for error in cases {
            let harness = AttributeHarness()
            let transcript = try AttributeFixture.transcript(segments: [
                try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
            ])
            let transcriptId = try await harness.seedTranscript(transcript)
            harness.port.forcedError = error

            let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

            assertPermanentFailure(outcome)
        }
    }

    // MARK: - К41 (пять StorageError — permanentFailure, на чтении и на применении)

    func test_k41_fiveStorageErrorsPermanentFailureAtReadAndApplicationStages() async throws {
        let cases: [StorageError] = [
            .notFound(entity: "Segment", id: "1"),
            .constraintViolation(message: "x"),
            .migrationFailed(identifier: "m1", message: "x"),
            .fileMissing(path: "/x"),
            .dataCorrupted(entity: "Segment", id: "1", message: "x")
        ]
        for error in cases {
            let readHarness = AttributeHarness()
            readHarness.transcripts.fail(with: error, on: .transcriptById)
            let readOutcome = await readHarness.run(AttributeFixture.job(transcriptId: UUID(), meetingId: nil))
            assertPermanentFailure(readOutcome)

            let applyHarness = try await Self.harnessWithSegmentUpdate()
            applyHarness.harness.transcripts.fail(with: error, on: .updateAttribution)
            let applyOutcome = await applyHarness.harness.run(
                AttributeFixture.job(transcriptId: applyHarness.transcriptId, meetingId: nil)
            )
            assertPermanentFailure(applyOutcome)
        }
    }

    // MARK: - К42 (StorageError.io — переходный случай, retry(after: 30))

    func test_k42_storageIoRetriesAfter30OnBothStages() async throws {
        let error = StorageError.io(message: "диск занят")

        let readHarness = AttributeHarness()
        readHarness.transcripts.fail(with: error, on: .transcriptById)
        let readOutcome = await readHarness.run(AttributeFixture.job(transcriptId: UUID(), meetingId: nil))
        assertRetry(readOutcome, after: 30)

        let applyHarness = try await Self.harnessWithSegmentUpdate()
        applyHarness.harness.transcripts.fail(with: error, on: .updateAttribution)
        let applyOutcome = await applyHarness.harness.run(
            AttributeFixture.job(transcriptId: applyHarness.transcriptId, meetingId: nil)
        )
        assertRetry(applyOutcome, after: 30)
    }

    // MARK: - К49 (AppFacadeError из settings() — оба пути отказа, MEE-420)

    func test_k49_settingsUnreadableIsPermanentFailure() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.appFacade.forcedError = .settingsUnreadable(key: "voiceProfilesEnabled")

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        assertPermanentFailure(outcome)
    }

    func test_k49_underlyingStorageIoRetriesAfter30() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.appFacade.forcedError = .underlying(AppErrorView(
            code: "storage.io", message: "диск занят", recoverySuggestion: nil, permissionKind: nil
        ))

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        assertRetry(outcome, after: 30)
    }

    /// Случай `AppFacadeError`, который §2.1 для `settings()` не называет —
    /// `permanentFailure` как безопасный исход неизвестного случая.
    func test_k49_otherAppFacadeErrorFromSettingsIsPermanentFailure() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.appFacade.forcedError = .notAllowed(reason: "неожиданный отказ")

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        assertPermanentFailure(outcome)
    }

    /// Оснастка «отказ на применении»: транскрипт с одним сегментом, `forcedResult` несёт
    /// непустой `segmentUpdates` — есть что применять, есть на чём словить отказ репозитория.
    private static func harnessWithSegmentUpdate() async throws -> (harness: AttributeHarness, transcriptId: UUID) {
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
        return (harness, transcriptId)
    }
}
