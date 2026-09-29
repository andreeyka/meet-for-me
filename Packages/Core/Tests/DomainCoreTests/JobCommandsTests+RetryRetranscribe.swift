//  JobCommandsTests — К37 в форме дельты АВ (f89d2865, MEE-401) и К65: C-016 v11 инв. 12 с
//  правкой IR-144 (запись раньше профиля) и новый инв. 32 (`retryJob`). Задача MEE-465.
//  Вектор А К37 (профилю не хватает моделей) — `test_k37_retranscribeMissingModelsThrowsProfileNotReady`
//  в `JobCommandsTests.swift`.
//
//  «Событий нет» наблюдается контрольным событием: после отказа тест вызывает
//  `updateSettings` и первым в потоке ждёт `settingsChanged` — любое событие отказа пришло бы
//  раньше него.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

/// Контрольное событие `settingsChanged` пришло первым и единственным — событий отказа до
/// него не было.
func assertOnlyControlEvent(_ events: [AppEvent], _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(events.count, 1, message, file: file, line: line)
    guard case .settingsChanged = events.first else {
        return XCTFail("\(message): ожидался .settingsChanged, получено \(events)", file: file, line: line)
    }
}

extension JobCommandsTests {

    // MARK: - К37, вход Б: записи нет — `notFound`, не `profileNotReady`

    func test_k37_retranscribeUnknownRecordingThrowsNotFoundBeforeProfileCheck() async throws {
        let fixture = ModelJobFixture()
        seedProfileMissingVad(fixture)
        let recordingId = UUID()
        do {
            _ = try await fixture.facade.retranscribe(recordingId: recordingId, profileId: "p1")
            XCTFail("ожидался notFound")
        } catch let error as AppFacadeError {
            XCTAssertEqual(error, .notFound(entity: "Recording", id: recordingId.uuidString),
                           "запись раньше профиля: не profileNotReady")
        }
        XCTAssertTrue(fixture.queue.submissions.isEmpty, "задача не ставится")
        XCTAssertEqual(fixture.queue.callLog.count(port: FakeJobQueue.portName, method: "submit(_:)"), 0)
    }

    // MARK: - К37, вход В: запись не `.finalized` — `notAllowed`, по вектору на статус

    func test_k37_retranscribeNonFinalizedRecordingThrowsNotAllowedForEachStatus() async throws {
        // Все статусы `RecordingStatus` C-010, кроме `.finalized`.
        let statuses: [RecordingStatus] = [.recording, .stopping, .failed]
        for status in statuses {
            for profileReady in [true, false] {
                let label = "status=\(status.rawValue), profileReady=\(profileReady)"
                let fixture = ModelJobFixture()
                if profileReady { seedProfileReady(fixture) } else { seedProfileMissingVad(fixture) }
                let recordingId = try await fixture.seedRecording(status: status)
                do {
                    _ = try await fixture.facade.retranscribe(recordingId: recordingId, profileId: "p1")
                    XCTFail("\(label): ожидался notAllowed")
                } catch AppFacadeError.notAllowed {
                } catch {
                    XCTFail("\(label): ожидался notAllowed, получено \(error)")
                }
                XCTAssertTrue(fixture.queue.submissions.isEmpty, "\(label): задача не ставится")
                XCTAssertEqual(fixture.queue.callLog.count(port: FakeJobQueue.portName, method: "submit(_:)"), 0, label)
            }
        }
    }

    /// Отказ чтения записи — `storage.*` по словарю §3.1; задача не ставится.
    func test_k37_retranscribeRecordingReadFailureIsStorageCodeAndSubmitsNothing() async throws {
        let fixture = ModelJobFixture()
        seedProfileReady(fixture)
        let recordingId = try await fixture.seedRecording()
        fixture.repositories.recordings.fail(with: .io(message: "disk"), on: .recordingById)
        let view = await underlyingView {
            _ = try await fixture.facade.retranscribe(recordingId: recordingId, profileId: "p1")
        }
        XCTAssertEqual(view?.code, "storage.io")
        XCTAssertTrue(fixture.queue.submissions.isEmpty)
    }

    // MARK: - К37, вход Г: запись `.finalized`, профиль готов — одна подача `standard`

    func test_k37_retranscribeFinalizedRecordingSubmitsStandardTranscribeWithPowerRule() async throws {
        for acOnly in [false, true] {
            let label = "processOnACPowerOnly=\(acOnly)"
            let fixture = ModelJobFixture()
            seedProfileReady(fixture)
            try await setProcessOnACPowerOnly(acOnly, in: fixture)
            let recordingId = try await fixture.seedRecording()
            let jobId = try await fixture.facade.retranscribe(recordingId: recordingId, profileId: "p1")
            XCTAssertEqual(fixture.queue.submissions.count, 1, label)
            let submission = try XCTUnwrap(fixture.queue.submissions.first, label)
            XCTAssertEqual(jobId, FakeJobQueue.deterministicId(1), "\(label): jobId этой подачи")
            let payload = JobPayload.transcribe(recordingId: recordingId, profileId: "p1", language: nil)
            XCTAssertEqual(submission.payload, payload, "\(label): transcribe, language == nil")
            let standard = JobSubmission.standard(payload, runAfter: submission.runAfter)
            XCTAssertEqual(submission.priority, standard.priority, label)
            XCTAssertEqual(submission.maxAttempts, standard.maxAttempts, label)
            XCTAssertEqual(submission.dedupKey, standard.dedupKey, label)
            XCTAssertEqual(submission.conditions.requiresACPower, acOnly, "\(label): правило «только от сети»")
            XCTAssertEqual(submission.conditions.forbidWhileRecording, standard.conditions.forbidWhileRecording, label)
            XCTAssertEqual(submission.conditions.maxThermalPressure, standard.conditions.maxThermalPressure, label)
            XCTAssertEqual(submission.conditions.requiresProfileReady, standard.conditions.requiresProfileReady, label)
        }
    }

    // MARK: - К65 (инв. 32): пять статусов

    /// Задача в `status`, подача которой заведомо отличается от `standard` для `transcribe`:
    /// иной приоритет и число попыток, поднятое `requiresACPower`, непустой `dedupKey`, —
    /// копия прежней подачи отличилась бы от сборки заново в каждом поле.
    static func job(status: JobStatus, id: UUID = UUID(),
                    payload: JobPayload = .transcribe(recordingId: UUID(), profileId: "p1", language: nil)) -> Job {
        let epoch = Date(timeIntervalSince1970: 0)
        return Job(
            id: id, type: .transcribe, payload: payload,
            status: status, priority: 99, attempts: 1, maxAttempts: 9, runAfter: epoch,
            conditions: JobConditions(requiresACPower: true, forbidWhileRecording: false,
                                      maxThermalPressure: .critical, requiresProfileReady: nil),
            dedupKey: "old-key", leaseExpiresAt: nil, attemptStartedAt: nil,
            lastError: nil, createdAt: epoch, updatedAt: epoch
        )
    }

    func test_k65_retryJobFromPendingRunningSucceededThrowsNotAllowedWithoutSubmissionOrEvents() async throws {
        for status in [JobStatus.pending, .running, .succeeded] {
            let label = "status=\(status.rawValue)"
            let fixture = ModelJobFixture()
            let previous = Self.job(status: status)
            fixture.queue.setJobs([previous])
            let stream = fixture.facade.events()
            do {
                _ = try await fixture.facade.retryJob(id: previous.id)
                XCTFail("\(label): ожидался notAllowed")
            } catch AppFacadeError.notAllowed {
            } catch {
                XCTFail("\(label): ожидался notAllowed, получено \(error)")
            }
            XCTAssertTrue(fixture.queue.submissions.isEmpty, "\(label): подач нет")
            XCTAssertEqual(fixture.queue.callLog.count(port: FakeJobQueue.portName, method: "submit(_:)"), 0, label)
            try await setProcessOnACPowerOnly(false, in: fixture)
            let events = await collectEvents(stream, count: 1)
            assertOnlyControlEvent(events, "\(label): отказ событий не публикует")
        }
    }

    func test_k65_retryJobFromFailedOrCancelledSubmitsRebuiltStandardWithNewId() async throws {
        for status in [JobStatus.failed, .cancelled] {
            let label = "status=\(status.rawValue)"
            let fixture = ModelJobFixture()
            let previous = Self.job(status: status)
            fixture.queue.setJobs([previous])
            let stream = fixture.facade.events()
            let jobId = try await fixture.facade.retryJob(id: previous.id)

            XCTAssertNotEqual(jobId, previous.id, "\(label): новый jobId")
            XCTAssertEqual(jobId, FakeJobQueue.deterministicId(1), "\(label): jobId новой подачи")
            XCTAssertEqual(fixture.queue.submissions.count, 1, "\(label): ровно одна подача")
            let submission = try XCTUnwrap(fixture.queue.submissions.first, label)
            let expected = JobSubmission.standard(previous.payload, runAfter: submission.runAfter)
            XCTAssertEqual(submission, expected, "\(label): собрана заново по таблице §4 C-013, не копия")
            XCTAssertEqual(submission.payload, previous.payload, "\(label): нагрузка прежняя")
            XCTAssertNil(submission.dedupKey, "\(label): dedupKey == nil")
            XCTAssertFalse(submission.conditions.requiresACPower,
                           "\(label): «только от сети» выключено — условие не скопировано с прежней задачи")

            let events = await collectEvents(stream, count: 1)
            guard case .statusChanged = events.first else {
                return XCTFail("\(label): ожидался .statusChanged, получено \(events)")
            }
        }
    }

    /// Первая подача шла при `processOnACPowerOnly == false`, перед повтором настройка
    /// включена: повтор несёт условие «только от сети», хотя первая подача его не несла.
    func test_k65_retryJobAppliesPowerRuleFromCurrentSettings() async throws {
        let fixture = ModelJobFixture()
        seedProfileReady(fixture)
        try await setProcessOnACPowerOnly(false, in: fixture)
        let recordingId = try await fixture.seedRecording()
        let firstId = try await fixture.facade.retranscribe(recordingId: recordingId, profileId: "p1")
        let first = try XCTUnwrap(fixture.queue.submissions.first)
        XCTAssertFalse(first.conditions.requiresACPower, "первая подача — без условия")

        let epoch = Date(timeIntervalSince1970: 0)
        fixture.queue.setJobs([Job(
            id: firstId, type: .transcribe, payload: first.payload, status: .failed,
            priority: first.priority, attempts: first.maxAttempts, maxAttempts: first.maxAttempts,
            runAfter: first.runAfter, conditions: first.conditions, dedupKey: first.dedupKey,
            leaseExpiresAt: nil, attemptStartedAt: nil, lastError: "engine.serviceCrashed",
            createdAt: epoch, updatedAt: epoch
        )])
        try await setProcessOnACPowerOnly(true, in: fixture)

        let retriedId = try await fixture.facade.retryJob(id: firstId)
        XCTAssertNotEqual(retriedId, firstId)
        XCTAssertEqual(fixture.queue.submissions.count, 2)
        let retried = try XCTUnwrap(fixture.queue.submissions.last)
        XCTAssertTrue(retried.conditions.requiresACPower, "повтор — по действующим настройкам")
        XCTAssertEqual(retried.payload, first.payload)
        XCTAssertEqual(retried.conditions.forbidWhileRecording, first.conditions.forbidWhileRecording)
        XCTAssertEqual(retried.conditions.maxThermalPressure, first.conditions.maxThermalPressure)
        XCTAssertEqual(retried.conditions.requiresProfileReady, first.conditions.requiresProfileReady)
        XCTAssertNil(retried.dedupKey)
    }
}
