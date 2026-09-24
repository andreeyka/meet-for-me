//  MEE-290: `DomainTestKit.FakeJobQueue` и `DomainTestKit.FakeJobHandler` —
//  §«Фейк для тестов» C-013 и условие `С` плана MEE-288 §2.
//
//  Условие `С` сказано так: «ЗАДАНИЕ СОСТАВА ЗАДАЧ записи через `jobs(status:)` и РАЗРЕШЕНИЕ
//  `jobId` → `Job.payload` через `job(id:)`». Обе половины стоят здесь векторами: пересказ
//  §4 постановки MEE-290 назвал только первую, и это названо находкой в отчёте.
//
//  ПОЧЕМУ `submit` НЕ ЗАВОДИТ СТРОКУ. Чтобы собрать `Job` из `JobSubmission`, фейку пришлось
//  бы вывести `Job.type` из `JobPayload` — написать тело `JobPayload.type`, которое П4 держит
//  (MEE-290 §2). Поэтому состав задаёт тест, и это проверяется здесь прямо: после `submit`
//  подача записана, а `job(id:)` на выданном идентификаторе молчит, пока состав не задан.
//
//  ГРАНИЦА НАЗВАНА: ни одно утверждение этого файла не говорит о поведении ОЧЕРЕДИ. Фейк не
//  держит ни дедупликации (инвариант 1 C-013), ни условий запуска, ни лизинга.

import Foundation
import XCTest
import DomainCore
import DomainTestKit

final class FakeJobQueueTests: XCTestCase {

    private let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId

    // MARK: - Все `submit` и `cancel` записаны и отданы списком

    func test_mee290_fakeJobQueue_recordsSubmissionsAndCancellations() async throws {
        let queue = FakeJobQueue()
        XCTAssertTrue(queue.submissions.isEmpty, "вектор непустоты: до вызовов список пуст")
        XCTAssertTrue(queue.cancellations.isEmpty)

        let first = submission(.transcode(recordingId: recordingId))
        let second = submission(.diarize(recordingId: recordingId, profileId: "ru-default"))
        let firstId = try await queue.submit(first)
        let secondId = try await queue.submit(second)
        try await queue.cancel(jobId: secondId)

        XCTAssertEqual(queue.submissions, [first, second], "порядок подачи сохранён")
        XCTAssertEqual(queue.cancellations, [secondId])
        XCTAssertNotEqual(firstId, secondId, "идентификаторы различны")
        XCTAssertEqual(firstId, FakeJobQueue.deterministicId(1), "идентификатор детерминирован")
        XCTAssertEqual(secondId, FakeJobQueue.deterministicId(2))
    }

    func test_mee290_fakeJobQueue_usesIdsGivenInAdvance() async throws {
        let queue = FakeJobQueue()
        let planned = [UUID(), UUID()]
        queue.setNextSubmitIds(planned)

        let first = try await queue.submit(submission(.transcode(recordingId: recordingId)))
        let second = try await queue.submit(submission(.transcode(recordingId: recordingId)))
        let third = try await queue.submit(submission(.transcode(recordingId: recordingId)))

        XCTAssertEqual([first, second], planned, "заданные наперёд идут по порядку")
        XCTAssertEqual(third, FakeJobQueue.deterministicId(1), "кончились заданные — счётчик с начала")
    }

    // MARK: - Условие `С`, половина первая: состав задаётся и читается `jobs(status:)`

    func test_mee290_fakeJobQueue_composesJobsByStatus() async throws {
        let queue = FakeJobQueue()
        let pendingA = job(type: .transcribe, payload: .transcribe(
            recordingId: recordingId, profileId: "ru-default", language: nil
        ), status: .pending)
        let pendingB = job(type: .diarize, payload: .diarize(
            recordingId: recordingId, profileId: "ru-default"
        ), status: .pending)
        let done = job(type: .transcode, payload: .transcode(recordingId: recordingId), status: .succeeded)
        queue.setJobs([pendingA, pendingB, done])

        let pending = try await queue.jobs(status: .pending)
        XCTAssertEqual(pending.map(\.id), [pendingA.id, pendingB.id], "порядок задания сохранён")
        let succeeded = try await queue.jobs(status: .succeeded)
        XCTAssertEqual(succeeded.map(\.id), [done.id])
        let running = try await queue.jobs(status: .running)
        XCTAssertEqual(running, [], "пустой статус даёт пустой ответ, а не весь состав")
        XCTAssertEqual(pending.count + succeeded.count, 3, "вектор непустоты: состав задан и виден")
    }

    // MARK: - Условие `С`, половина вторая: `jobId` → `Job.payload` через `job(id:)`

    func test_mee290_fakeJobQueue_resolvesJobIdIntoPayload() async throws {
        let queue = FakeJobQueue()
        let transcriptId = UUID()
        let attribute = job(
            type: .attribute,
            payload: .attribute(transcriptId: transcriptId, meetingId: nil),
            status: .pending
        )
        queue.setJobs([attribute])

        let resolved = try await queue.job(id: attribute.id)
        let row = try XCTUnwrap(resolved, "задача, состав которой задан, разрешается")
        XCTAssertEqual(row.payload, JobPayload.attribute(transcriptId: transcriptId, meetingId: nil))
        XCTAssertEqual(row.type, JobType.attribute)

        let absent = try await queue.job(id: UUID())
        XCTAssertNil(absent, "вектор непустоты отбора: чужой идентификатор не разрешается")
    }

    /// Строку `submit` не заводит: `Job.type` выводить нечем, пока П4 держит `JobPayload.type`.
    func test_mee290_fakeJobQueue_submitDoesNotInventAJobRow() async throws {
        let queue = FakeJobQueue()
        let identifier = try await queue.submit(submission(.transcode(recordingId: recordingId)))
        XCTAssertEqual(queue.submissions.count, 1, "вектор непустоты: подача записана")

        let invented = try await queue.job(id: identifier)
        XCTAssertNil(invented, "строки нет, пока состав не задан тестом")
        let pending = try await queue.jobs(status: .pending)
        XCTAssertEqual(pending, [], "и в составе её нет")
    }

    // MARK: - Любой `JobEvent` в поток; регистрация обработчика; отказ `submit`

    func test_mee290_fakeJobQueue_pushesAnyEventIntoStream() async {
        let queue = FakeJobQueue()
        let stream = queue.events()          // поток берётся ДО толчка
        let identifier = UUID()
        let pushed: [JobEvent] = [
            .submitted(jobId: identifier, type: .transcode),
            .started(jobId: identifier, type: .transcode),
            .progressed(jobId: identifier, fraction: 0.5),
            .blocked(jobId: identifier, type: .transcode, reason: .waitingForACPower),
            .failed(jobId: identifier, type: .transcode, error: "нет места", willRetry: true),
            .cancelled(jobId: identifier, type: .transcode),
            .succeeded(jobId: identifier, type: .transcode)
        ]
        for event in pushed {
            queue.emit(event)
        }
        queue.finishEvents()

        var seen: [JobEvent] = []
        for await event in stream {
            seen.append(event)
        }
        XCTAssertEqual(seen.count, 7, "вектор непустоты: поток не пуст и не обрезан")
        XCTAssertEqual(seen, pushed)
    }

    func test_mee290_fakeJobQueue_registerRejectsSecondHandlerOfSameType() async throws {
        let queue = FakeJobQueue()
        try await queue.register(handler: FakeJobHandler(type: .transcode))
        try await queue.register(handler: FakeJobHandler(type: .transcribe))
        XCTAssertEqual(queue.registeredHandlerTypes, [.transcode, .transcribe], "вектор непустоты")

        do {
            try await queue.register(handler: FakeJobHandler(type: .transcode))
            XCTFail("ожидался handlerAlreadyRegistered")
        } catch let error as JobQueueError {
            XCTAssertEqual(error, .handlerAlreadyRegistered(.transcode))
        }
        XCTAssertEqual(queue.registeredHandlerTypes.count, 2, "второй регистрации не случилось")
    }

    func test_mee290_fakeJobQueue_submitFailsWhenAsked() async throws {
        let queue = FakeJobQueue()
        queue.failSubmit(with: JobQueueError.invalidPriority(500))
        do {
            _ = try await queue.submit(submission(.transcode(recordingId: recordingId)))
            XCTFail("ожидался отказ submit")
        } catch let error as JobQueueError {
            XCTAssertEqual(error, .invalidPriority(500))
        }
        XCTAssertEqual(queue.submissions, [], "отказавшая подача в список не легла")

        queue.failSubmit(with: nil)
        _ = try await queue.submit(submission(.transcode(recordingId: recordingId)))
        XCTAssertEqual(queue.submissions.count, 1, "отказ снимается")
    }

    func test_mee290_fakeJobQueue_countsStartAndStop() async {
        let queue = FakeJobQueue()
        XCTAssertEqual(queue.startCallCount, 0, "вектор непустоты: до вызовов ноль")
        await queue.start()
        await queue.start()
        await queue.stop()
        XCTAssertEqual(queue.startCallCount, 2)
        XCTAssertEqual(queue.stopCallCount, 1)
    }

    /// C-013 v9: `recordingDidStart`/`recordingDidStop` — часть протокола `JobQueue`
    /// (возврат РП, MEE-350) — фейк лишь считает вызовы, ничего не пересматривает.
    func test_mee350_fakeJobQueue_countsRecordingSignals() async {
        let queue = FakeJobQueue()
        XCTAssertEqual(queue.recordingDidStartCallCount, 0, "вектор непустоты: до вызовов ноль")
        XCTAssertEqual(queue.recordingDidStopCallCount, 0)
        await queue.recordingDidStart()
        await queue.recordingDidStart()
        await queue.recordingDidStop()
        XCTAssertEqual(queue.recordingDidStartCallCount, 2)
        XCTAssertEqual(queue.recordingDidStopCallCount, 1)
    }

    // MARK: - `FakeJobHandler`

    func test_mee290_fakeJobHandler_returnsGivenOutcomeAndCountsRuns() async {
        let handler = FakeJobHandler(type: .transcribe)
        handler.setOutcome(.retry(after: 30, error: "движок занят"))
        handler.setProgressSteps([0.25, 0.75])
        XCTAssertEqual(handler.runCallCount, 0, "вектор непустоты: до вызовов ноль")

        let row = job(type: .transcribe, payload: .transcribe(
            recordingId: recordingId, profileId: "ru-default", language: nil
        ), status: .running)
        let collected = ProgressBox()
        let outcome = await handler.run(row) { fraction in collected.add(fraction) }

        XCTAssertEqual(outcome, .retry(after: 30, error: "движок занят"), "исход тот, что задали")
        XCTAssertEqual(collected.values, [0.25, 0.75], "доли отданы по порядку")
        XCTAssertEqual(handler.runCallCount, 1, "число исполнений — инвариант 6 наблюдается им")
        XCTAssertEqual(handler.observedJobs.map(\.id), [row.id], "строка задачи отдана В МОМЕНТ вызова")
        XCTAssertEqual(handler.observedJobs.first?.attemptStartedAt, row.attemptStartedAt)
    }

    func test_mee290_fakeJobHandler_typeIsFixedAtBirth() {
        for type in JobType.allCases {
            XCTAssertEqual(FakeJobHandler(type: type).type, type)
        }
        XCTAssertEqual(JobType.allCases.count, 5, "вектор непустоты: перебор непуст и полон")
    }

    // MARK: - Оснастка

    private func submission(_ payload: JobPayload) -> JobSubmission {
        JobSubmission(
            payload: payload,
            priority: 0,
            maxAttempts: 3,
            runAfter: Date(timeIntervalSince1970: 0),
            conditions: conditions(),
            dedupKey: nil
        )
    }

    private func job(type: JobType, payload: JobPayload, status: JobStatus) -> Job {
        Job(
            id: UUID(),
            type: type,
            payload: payload,
            status: status,
            priority: 0,
            attempts: 0,
            maxAttempts: 3,
            runAfter: Date(timeIntervalSince1970: 0),
            conditions: conditions(),
            dedupKey: nil,
            leaseExpiresAt: nil,
            attemptStartedAt: nil,
            lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func conditions() -> JobConditions {
        JobConditions(
            requiresACPower: false,
            forbidWhileRecording: false,
            maxThermalPressure: .serious,
            requiresProfileReady: nil
        )
    }
}

/// Сборщик долей прогресса: замыкание `@Sendable`, и копить в локальной переменной нечем.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Double] = []

    func add(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
