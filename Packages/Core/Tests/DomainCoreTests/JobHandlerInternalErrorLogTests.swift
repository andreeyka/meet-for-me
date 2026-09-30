//  JobHandlerInternalErrorLogTests — журнал причины `app.internalError` в обработчиках задач
//  (MEE-511, IR-155; решение архитектора MEE-493 п. 3, критерии 1–4; module-map, domain-core,
//  «Журнал»). Замыкание `log` вызывается ровно один раз на каждой ветке `internalErrorCode`, строка
//  несёт вид обработчика, тип и описание ошибки, без текста транскрипта и названия встречи;
//  строка очереди остаётся `app.internalError` дословно (регрессия MEE-506).
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен

import XCTest
import Foundation
@testable import DomainCore
import DomainTestKit

final class JobHandlerInternalErrorLogTests: XCTestCase {

    // MARK: - Оснастка

    /// Ошибка вне словаря §3.1 — попадает в ветку «всё прочее».
    private struct ProbeError: LocalizedError {
        var errorDescription: String? { "зонд: отказ вне словаря" }
    }

    private static let probeType = String(reflecting: ProbeError.self)

    /// Накапливающее замыкание журнала.
    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var closure: @Sendable (String) -> Void {
            { [self] line in
                lock.lock()
                defer { lock.unlock() }
                stored.append(line)
            }
        }
    }

    /// `TranscriptRepository`, у которого `save` бросает ошибку вне `StorageError`; прочее — к фейку.
    private struct SaveThrowingRepository: TranscriptRepository {
        let base = InMemoryTranscriptRepository()

        func save(_ transcript: Transcript) async throws -> TranscriptHeader { throw ProbeError() }
        func headers(recordingId: UUID) async throws -> [TranscriptHeader] {
            try await base.headers(recordingId: recordingId)
        }
        func latest(recordingId: UUID) async throws -> TranscriptHeader? {
            try await base.latest(recordingId: recordingId)
        }
        func transcript(id: UUID) async throws -> Transcript? { try await base.transcript(id: id) }
        func segments(transcriptId: UUID) async throws -> [SegmentRow] {
            try await base.segments(transcriptId: transcriptId)
        }
        func updateAttribution(_ updates: [SegmentAttributionUpdate]) async throws {
            try await base.updateAttribution(updates)
        }
        func updateSegmentText(segmentId: Int64, text: String, isUserEdited: Bool) async throws -> UUID {
            try await base.updateSegmentText(segmentId: segmentId, text: text, isUserEdited: isUserEdited)
        }
        func markSegmentsUserEdited(segmentIds: [Int64]) async throws {
            try await base.markSegmentsUserEdited(segmentIds: segmentIds)
        }
        func applyTextCorrections(segmentId: Int64, text: String, corrections: [TextCorrection]) async throws {
            try await base.applyTextCorrections(segmentId: segmentId, text: text, corrections: corrections)
        }
        func search(query: String, limit: Int, offset: Int) async throws -> [SearchHit] {
            try await base.search(query: query, limit: limit, offset: offset)
        }
    }

    /// `AttributionPort`, бросающий ошибку вне `AttributionError`.
    private struct ThrowingAttributionPort: AttributionPort {
        func attribute(_ input: AttributionInput, thresholds: AttributionThresholds) async throws
            -> AttributionResult { throw ProbeError() }
        func confirm(transcriptId: UUID, cluster: Int, personId: UUID, input: AttributionInput) async throws
            -> AttributionResult { throw ProbeError() }
        func reject(transcriptId: UUID, cluster: Int, input: AttributionInput) async throws
            -> AttributionResult { throw ProbeError() }
    }

    private func transcribeJob() -> Job {
        Job(
            id: UUID(), type: .transcribe,
            payload: .transcribe(
                recordingId: TranscriptFixtures.oneOnOne.recordingId, profileId: "ru-default", language: nil
            ),
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

    private func queueString(_ outcome: JobOutcome) -> String? {
        switch outcome {
        case .retry(_, let error), .permanentFailure(let error): return error
        case .success: return nil
        }
    }

    /// К3: вид обработчика, тип и описание ошибки есть; текста транскрипта нет.
    private func assertLogLine(
        _ line: String, handler: String, step: String, jobId: UUID,
        file: StaticString = #filePath, line lineNo: UInt = #line
    ) {
        XCTAssertTrue(line.contains(handler), line, file: file, line: lineNo)
        XCTAssertTrue(line.contains("[\(step)]"), line, file: file, line: lineNo)
        XCTAssertTrue(line.contains(Self.probeType), line, file: file, line: lineNo)
        XCTAssertTrue(line.contains("зонд: отказ вне словаря"), line, file: file, line: lineNo)
        XCTAssertTrue(line.contains(jobId.uuidString), line, file: file, line: lineNo)
        for segment in TranscriptFixtures.oneOnOne.segments {
            XCTAssertFalse(
                line.contains(segment.text), "текст транскрипта в журнале: \(line)", file: file, line: lineNo
            )
        }
    }

    // MARK: - TranscribeJobHandler

    /// К2–К4: `catch` вокруг `port.transcribe` — одна строка журнала, очередь — код дословно.
    func test_transcribe_internalErrorFromPort_logsOnce_queueStringIsCode() async {
        let sink = LogSink()
        let port = FakeTranscriptionServicePort()
        port.forcedResult = { throw ProbeError() }
        let handler = TranscribeJobHandler(port: port, transcripts: InMemoryTranscriptRepository(), log: sink.closure)
        let job = transcribeJob()

        let outcome = await handler.run(job, progress: { _ in })

        guard case .permanentFailure(let error) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(error, "app.internalError")
        XCTAssertEqual(sink.lines.count, 1, "\(sink.lines)")
        assertLogLine(sink.lines[0], handler: "TranscribeJobHandler", step: "transcribe", jobId: job.id)
    }

    /// К2–К4: `save` бросил ошибку вне `StorageError` — одна строка, в ней нет текста сохраняемого
    /// транскрипта; очередь — `retry(30, "app.internalError")`.
    func test_transcribe_internalErrorFromSave_logsOnce_withoutTranscriptText() async {
        let sink = LogSink()
        let port = FakeTranscriptionServicePort()
        let handler = TranscribeJobHandler(port: port, transcripts: SaveThrowingRepository(), log: sink.closure)
        let job = transcribeJob()

        let outcome = await handler.run(job, progress: { _ in })

        guard case .retry(let after, let error) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(after, 30)
        XCTAssertEqual(error, "app.internalError")
        XCTAssertEqual(sink.lines.count, 1, "\(sink.lines)")
        assertLogLine(sink.lines[0], handler: "TranscribeJobHandler", step: "save", jobId: job.id)
    }

    /// К2 (ровно на ветках `internalErrorCode`): прочие исходы журнал не трогают.
    func test_transcribe_otherOutcomes_doNotLog() async {
        let vectors: [(FakeTranscriptionServicePort, InMemoryTranscriptRepository) -> Void] = [
            { _, _ in },
            { port, _ in port.forcedError = .serviceCrashed },
            { port, _ in port.forcedError = .engineFailure(code: "audioUnreadable", message: "m") },
            { _, repository in repository.fail(with: .io(message: "диск"), on: .save) }
        ]
        for configure in vectors {
            let sink = LogSink()
            let port = FakeTranscriptionServicePort()
            let repository = InMemoryTranscriptRepository()
            configure(port, repository)
            let handler = TranscribeJobHandler(port: port, transcripts: repository, log: sink.closure)
            let outcome = await handler.run(transcribeJob(), progress: { _ in })
            XCTAssertNotEqual(queueString(outcome), "app.internalError")
            XCTAssertEqual(sink.lines, [], "\(outcome)")
        }
    }

    // MARK: - AttributeJobHandler

    private func attributeHandler(
        _ harness: AttributeHarness, port: AttributionPort, log: @escaping @Sendable (String) -> Void
    ) -> AttributeJobHandler {
        AttributeJobHandler(
            port: port, transcripts: harness.transcripts, meetings: harness.meetings,
            persons: harness.persons, speakerProfiles: harness.speakerProfiles,
            appFacade: harness.appFacade, log: log
        )
    }

    /// К2–К4: ветка «всё прочее» — одна строка; ни названия встречи, ни текста транскрипта.
    func test_attribute_internalError_logsOnce_withoutMeetingTitleOrTranscriptText() async throws {
        let harness = AttributeHarness()
        let secretWord = "секретнаяфразатранскрипта"
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word(secretWord)])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        let meetingEvent = try AttributeFixture.meetingEvent(id: UUID(), attendees: [])
        try await harness.meetings.save(MeetingRecord(
            event: meetingEvent, dedupKey: nil, status: .scheduled, sources: []
        ))
        let sink = LogSink()
        let job = AttributeFixture.job(transcriptId: transcriptId, meetingId: meetingEvent.id)

        let outcome = await attributeHandler(harness, port: ThrowingAttributionPort(), log: sink.closure)
            .run(job, progress: { _ in })

        guard case .permanentFailure(let error) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(error, "app.internalError")
        XCTAssertEqual(sink.lines.count, 1, "\(sink.lines)")
        let line = sink.lines[0]
        assertLogLine(line, handler: "AttributeJobHandler", step: "attribute", jobId: job.id)
        XCTAssertFalse(line.contains(secretWord), line)
        XCTAssertFalse(line.contains(meetingEvent.title), line)
    }

    /// К2: отказы из словаря (`AttributionError`, `StorageError`) журнал не трогают.
    func test_attribute_otherOutcomes_doNotLog() async throws {
        let seeded = AttributeHarness()
        let transcriptId = try await seeded.seedTranscript(try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ]))
        seeded.port.forcedError = .unknownPerson(UUID())
        let sink = LogSink()
        let attribution = await attributeHandler(seeded, port: seeded.port, log: sink.closure)
            .run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil), progress: { _ in })
        XCTAssertEqual(queueString(attribution), "attribution.unknownPerson")

        let storage = AttributeHarness()
        storage.transcripts.fail(with: .io(message: "диск"), on: .transcriptById)
        let storageOutcome = await attributeHandler(storage, port: storage.port, log: sink.closure)
            .run(AttributeFixture.job(transcriptId: UUID(), meetingId: nil), progress: { _ in })
        XCTAssertEqual(queueString(storageOutcome), "storage.io")

        XCTAssertEqual(sink.lines, [])
    }
}
