//  JobHandlerFailureTextTests — строки, которые обработчики задач пишут в очередь (MEE-498, бэклог
//  приёмки #216): код C-016 §3.1 либо текст для человека, без описания значения Swift и без
//  идентификаторов; `UnderlyingErrorText.jobFailureDetail` понимает каждую из них и даёт
//  подробность для `facade.jobFailed` (инв. 31, 37).
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен

import XCTest
@testable import DomainCore
import DomainTestKit

final class JobHandlerFailureTextTests: XCTestCase {

    private struct UnrelatedError: Error {}

    private func transcribeJob(payload: JobPayload? = nil) -> Job {
        let recordingId = TranscriptFixtures.oneOnOne.recordingId
        return Job(
            id: UUID(), type: .transcribe,
            payload: payload ?? .transcribe(recordingId: recordingId, profileId: "ru-default", language: nil),
            status: .running, priority: 0, attempts: 0, maxAttempts: 3,
            runAfter: Date(timeIntervalSince1970: 0),
            conditions: JobConditions(
                requiresACPower: false, forbidWhileRecording: false,
                maxThermalPressure: .critical, requiresProfileReady: nil
            ),
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func errorText(_ outcome: JobOutcome, file: StaticString = #filePath, line: UInt = #line) -> String {
        switch outcome {
        case .permanentFailure(let error), .retry(_, let error):
            return error
        case .success:
            XCTFail("ожидался отказ, получен .success", file: file, line: line)
            return ""
        }
    }

    /// Строка очереди: ни скобок значения Swift, ни UUID; подробность показа есть и тоже без них.
    private func assertHumanReadable(
        _ raw: String, expected: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(raw, expected, file: file, line: line)
        XCTAssertFalse(raw.contains("("), raw, file: file, line: line)
        let uuid = raw.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-", options: .regularExpression)
        XCTAssertNil(uuid, raw, file: file, line: line)
        let detail = UnderlyingErrorText.jobFailureDetail(raw)
        XCTAssertNotNil(detail, "jobFailureDetail не понял «\(raw)»", file: file, line: line)
        XCTAssertFalse(detail?.contains("(") ?? true, "\(raw): «\(detail ?? "")»", file: file, line: line)
    }

    // MARK: - TranscribeJobHandler

    private func runTranscribe(
        _ configure: (FakeTranscriptionServicePort, InMemoryTranscriptRepository) -> Void,
        job: Job? = nil
    ) async -> JobOutcome {
        let port = FakeTranscriptionServicePort()
        let repository = InMemoryTranscriptRepository()
        configure(port, repository)
        let handler = TranscribeJobHandler(port: port, transcripts: repository)
        return await handler.run(job ?? transcribeJob(), progress: { _ in })
    }

    func test_transcribeHandler_writesCodeOrHumanText() async {
        let wrongPayload = await runTranscribe({ _, _ in }, job: transcribeJob(payload: .diarize(
            recordingId: UUID(), profileId: "p"
        )))
        assertHumanReadable(errorText(wrongPayload), expected: UnderlyingErrorText.wrongPayloadText)

        let unrelated = await runTranscribe { port, _ in port.forcedResult = { throw UnrelatedError() } }
        assertHumanReadable(errorText(unrelated), expected: "app.internalError")

        let unknownCode = await runTranscribe { port, _ in
            port.forcedError = .engineFailure(code: "codeFromNewerService", message: "что-то новое")
        }
        assertHumanReadable(errorText(unknownCode), expected: "engine.engineFailure.codeFromNewerService")

        for cancelled in [TranscriptionServiceError.cancelled, .engineFailure(code: "cancelled", message: "стоп")] {
            let outcome = await runTranscribe { port, _ in port.forcedError = cancelled }
            assertHumanReadable(errorText(outcome), expected: TranscribeJobHandler.cancelledWithoutRequestText)
        }

        let saveFailure = await runTranscribe { _, repository in
            repository.fail(with: .io(message: "диск"), on: .save)
        }
        assertHumanReadable(errorText(saveFailure), expected: "storage.io")
    }

    // MARK: - AttributeJobHandler

    private func seededHarness() async throws -> (harness: AttributeHarness, transcriptId: UUID) {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        return (harness, try await harness.seedTranscript(transcript))
    }

    func test_attributeHandler_writesCodeOrHumanText() async throws {
        let wrongPayload = await AttributeHarness().run(AttributeFixture.job(payload: .transcode(recordingId: UUID())))
        assertHumanReadable(errorText(wrongPayload), expected: UnderlyingErrorText.wrongPayloadText)

        let missing = await AttributeHarness().run(AttributeFixture.job(transcriptId: UUID(), meetingId: nil))
        assertHumanReadable(errorText(missing), expected: "Транскрипт не найден — возможно, он уже удалён")

        let attribution = try await seededHarness()
        attribution.harness.port.forcedError = .unknownPerson(UUID())
        let attributionOutcome = await attribution.harness.run(
            AttributeFixture.job(transcriptId: attribution.transcriptId, meetingId: nil)
        )
        assertHumanReadable(errorText(attributionOutcome), expected: "attribution.unknownPerson")

        let storage = AttributeHarness()
        storage.transcripts.fail(with: .dataCorrupted(entity: "Transcript", id: "x", message: "m"), on: .transcriptById)
        let storageOutcome = await storage.run(AttributeFixture.job(transcriptId: UUID(), meetingId: nil))
        assertHumanReadable(errorText(storageOutcome), expected: "storage.dataCorrupted")
    }

    /// `AppFacadeError` из `settings()`: `facade.<case>`, у `underlying(view)` — `view.code` (инв. 37).
    func test_attributeHandler_appFacadeErrorIsWrittenAsCode() async throws {
        let vectors: [(AppFacadeError, String)] = [
            (.settingsUnreadable(key: "voiceProfilesEnabled"), "facade.settingsUnreadable"),
            (.notAllowed(reason: "неожиданный отказ"), "facade.notAllowed"),
            (.underlying(AppErrorView(
                code: "storage.dataCorrupted", message: "m", recoverySuggestion: nil, permissionKind: nil
            )), "storage.dataCorrupted"),
            (.underlying(AppErrorView(
                code: "storage.io", message: "m", recoverySuggestion: nil, permissionKind: nil
            )), "storage.io")
        ]
        for (error, expected) in vectors {
            let seeded = try await seededHarness()
            seeded.harness.appFacade.forcedError = error
            let job = AttributeFixture.job(transcriptId: seeded.transcriptId, meetingId: nil)
            let outcome = await seeded.harness.run(job)
            assertHumanReadable(errorText(outcome), expected: expected)
        }
    }
}
