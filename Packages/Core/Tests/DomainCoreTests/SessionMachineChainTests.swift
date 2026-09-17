//  Обработка и цепочка §8.7 — К42, К43, К62, К63, К64, К65, К66.
//  MEE-300, часть B. Пункты плана MEE-288 §3, разделы Ж и З, части 3/8 и 4/8.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineChainTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    /// Стенд, доведённый до `processing` строкой 12. Идентификаторы задач заданы наперёд:
    /// иначе `job(id:)` нечем удовлетворить, а К63 требует именно его.
    private func processing() async throws -> (SessionMachineBench, MeetingEvent, UUID, [UUID]) {
        let stand = SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: .auto),
            weights: try SessionMachineFixtures.weights()
        )
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        let ids = [UUID(), UUID(), UUID(), UUID()]
        stand.queue.setNextSubmitIds(ids)

        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let live = try unwrap(await stand.machine.sessions().first)
        let recordingId = try XCTUnwrap(live.recordingId)

        try await stand.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(70))
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: event.id)
        await stand.deliver(CaptureEvent.stopped(manifest))
        await stand.machine.tick(now: moment.addingTimeInterval(80))
        let inProcessing = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(inProcessing.state, .processing, "оснастка: сессия в обработке")
        return (stand, event, recordingId, ids)
    }

    /// Провести цепочку до конца: на каждый `succeeded` предыдущей ставится следующая.
    private func runChain(
        _ stand: SessionMachineBench,
        recordingId: UUID,
        ids: [UUID],
        upTo last: Int
    ) async throws {
        let payloads: [JobPayload] = [
            .transcode(recordingId: recordingId),
            .transcribe(recordingId: recordingId, profileId: "profile-1", language: nil),
            .diarize(recordingId: recordingId, profileId: "profile-1")
        ]
        for index in 0..<last {
            stand.queue.setJobs([SessionMachineFixtures.job(id: ids[index], payload: payloads[index])])
            await stand.deliver(JobEvent.succeeded(jobId: ids[index], type: payloads[index].type))
            await stand.machine.tick(now: moment.addingTimeInterval(100 + Double(index)))
        }
    }

    // MARK: - К62 (§8.7; инв. 20, первая половина)

    /// Порядок цепочки и «первая ставится при входе в `processing` строкой 12». Реализация,
    /// ставящая всю цепочку сразу, красна журналом: четыре `submit` вместо одного.
    func test_k62_theChainIsSubmittedOneLinkAtATimeInTheNamedOrder() async throws {
        let (stand, _, recordingId, ids) = try await processing()
        XCTAssertEqual(stand.queue.submissions.count, 1, "при входе в `processing` — ровно одна")
        XCTAssertEqual(stand.queue.submissions.first?.payload, .transcode(recordingId: recordingId))

        _ = try await stand.repositories.transcripts.save(
            try SessionMachineFixtures.transcript(recordingId: recordingId)
        )
        try await runChain(stand, recordingId: recordingId, ids: ids, upTo: 3)

        let types = stand.queue.submissions.map(\.payload.type)
        XCTAssertEqual(types, [.transcode, .transcribe, .diarize, .attribute], "порядок §8.7")
        await stand.machine.stop()
    }

    /// «Ни по какому иному событию»: ни `tick`, ни `blocked`, ни `failed(willRetry: true)`,
    /// ни чужой `succeeded` следующей задачи не ставят.
    func test_k62_noOtherEventEverAdvancesTheChain() async throws {
        let (stand, _, recordingId, ids) = try await processing()
        stand.queue.setJobs([SessionMachineFixtures.job(
            id: ids[0], payload: .transcode(recordingId: recordingId)
        )])

        await stand.machine.tick(now: moment.addingTimeInterval(100))
        await stand.deliver(JobEvent.blocked(jobId: ids[0], type: .transcode, reason: .waitingForACPower))
        await stand.deliver(JobEvent.failed(
            jobId: ids[0], type: .transcode, error: "временный", willRetry: true
        ))
        await stand.deliver(JobEvent.succeeded(jobId: UUID(), type: .transcode))
        await stand.machine.tick(now: moment.addingTimeInterval(110))

        XCTAssertEqual(stand.queue.submissions.count, 1, "цепочка не двинулась ни на одном входе")
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .processing)
        await stand.machine.stop()
    }

    // MARK: - К63 (§8.7, поля задач)

    /// Поля каждой задачи: `profileId` из настроек, `runAfter == now`, `language == nil`,
    /// `transcriptId` — ИЗ ХРАНИЛИЩА, `meetingId` — сессии.
    func test_k63_everyFieldOfEveryChainJobComesFromItsNamedSource() async throws {
        let (stand, event, recordingId, ids) = try await processing()
        let header = try await stand.repositories.transcripts.save(
            try SessionMachineFixtures.transcript(recordingId: recordingId)
        )
        try await runChain(stand, recordingId: recordingId, ids: ids, upTo: 3)

        let submissions = stand.queue.submissions
        XCTAssertEqual(submissions.count, 4)
        XCTAssertEqual(
            submissions[1].payload,
            .transcribe(recordingId: recordingId, profileId: "profile-1", language: nil)
        )
        XCTAssertEqual(submissions[2].payload, .diarize(recordingId: recordingId, profileId: "profile-1"))
        XCTAssertEqual(submissions[3].payload, .attribute(transcriptId: header.id, meetingId: event.id))
        XCTAssertEqual(submissions[3].runAfter, moment.addingTimeInterval(102), "`runAfter == now`")

        // Значения §4 C-013 — тем, что их отдаёт `standard`, а не литералом в машине.
        for submission in submissions {
            let reference = JobSubmission.standard(submission.payload, runAfter: submission.runAfter)
            XCTAssertEqual(submission, reference, "подача равна ответу `standard` поле в поле")
        }
        // `jobId` разрешается в нагрузку методом `job(id:)`, а не читается из события.
        XCTAssertTrue(stand.log.signatures.contains("JobQueue.job(id:)"), "нагрузка взята `job(id:)`")
        XCTAssertTrue(
            stand.log.signatures.contains("TranscriptRepository.latest(recordingId:)"),
            "`transcriptId` взят из хранилища"
        )
        await stand.machine.stop()
    }

    /// У ad-hoc-сессии `meetingId` задачи `attribute` равен `nil`: подставлять его нечем.
    func test_k63_adHocAttributeCarriesNoMeetingId() async throws {
        let stand = SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: .manual),
            weights: try SessionMachineFixtures.weights()
        )
        stand.allowCaptureStart()
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        let ids = [UUID(), UUID(), UUID(), UUID()]
        stand.queue.setNextSubmitIds(ids)
        await stand.machine.start(now: moment)
        await stand.deliver(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: moment))
        await stand.machine.tick(now: moment)

        let recordingId = try await stand.machine.startRecording(meetingId: nil, now: moment)
        try await stand.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(10))
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: nil)
        await stand.deliver(CaptureEvent.stopped(manifest))
        await stand.machine.tick(now: moment.addingTimeInterval(20))

        let header = try await stand.repositories.transcripts.save(
            try SessionMachineFixtures.transcript(recordingId: recordingId)
        )
        try await runChain(stand, recordingId: recordingId, ids: ids, upTo: 3)
        XCTAssertEqual(
            stand.queue.submissions.last?.payload,
            .attribute(transcriptId: header.id, meetingId: nil),
            "у ad-hoc `meetingId` равен `nil` на всю жизнь сессии"
        )
        await stand.machine.stop()
    }

    // MARK: - К64 (§8.7, `blocked`; инв. 20, вторая половина)

    /// `blocked` и `failed(willRetry: true)` — не отказ: состояние не меняется, следующая
    /// задача не ставится, `setStatus` не зовётся.
    func test_k64_blockedAndRetryableFailureChangeNothing() async throws {
        let (stand, _, recordingId, ids) = try await processing()
        stand.queue.setJobs([SessionMachineFixtures.job(
            id: ids[0], payload: .transcode(recordingId: recordingId)
        )])
        let statusCallsBefore = stand.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)")

        for _ in 0..<3 {
            await stand.deliver(JobEvent.blocked(jobId: ids[0], type: .transcode, reason: .thermalPressure))
        }
        await stand.deliver(JobEvent.failed(
            jobId: ids[0], type: .transcode, error: "сеть", willRetry: true
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(120))

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .processing, "блокировка провалом не считается")
        XCTAssertEqual(stand.queue.submissions.count, 1, "ноль лишних `submit`")
        XCTAssertEqual(
            stand.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)"),
            statusCallsBefore,
            "ноль лишних `setStatus`"
        )
        await stand.machine.stop()
    }

    // MARK: - К42 (строка 14: processing → ready)

    /// Переход в `ready` наступает ТОЛЬКО на `succeeded` своей `attribute`.
    func test_k42_row14_firesOnlyOnTheOwnAttributeJob() async throws {
        let (stand, _, recordingId, ids) = try await processing()
        _ = try await stand.repositories.transcripts.save(
            try SessionMachineFixtures.transcript(recordingId: recordingId)
        )
        try await runChain(stand, recordingId: recordingId, ids: ids, upTo: 3)

        let midway = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(midway.state, .processing, "на трёх промежуточных состояние не менялось")

        // Чужая `attribute`: `jobId` машина не ставила, и не происходит ничего.
        await stand.deliver(JobEvent.succeeded(jobId: UUID(), type: .attribute))
        await stand.machine.tick(now: moment.addingTimeInterval(130))
        let stillProcessing = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(stillProcessing.state, .processing, "чужая `attribute` не делает ничего")

        await stand.deliver(JobEvent.succeeded(jobId: ids[3], type: .attribute))
        await stand.machine.tick(now: moment.addingTimeInterval(140))
        let afterAttribute = await stand.machine.sessions()
        XCTAssertTrue(afterAttribute.isEmpty, "своя `attribute` уводит в `ready`")
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .ready)
        await stand.machine.stop()
    }

    // MARK: - К43 (строка 15: processing → failed)

    /// `failed(willRetry: false)` и `cancelled` ЛЮБОЙ задачи цепочки уводят в `failed`.
    func test_k43_row15_firesOnAPermanentFailureOrCancellationOfAnyChainJob() async throws {
        for isCancelled in [false, true] {
            let (stand, _, recordingId, ids) = try await processing()
            stand.queue.setJobs([SessionMachineFixtures.job(
                id: ids[0], payload: .transcode(recordingId: recordingId)
            )])
            let event: JobEvent = isCancelled
                ? .cancelled(jobId: ids[0], type: .transcode)
                : .failed(jobId: ids[0], type: .transcode, error: "битый файл", willRetry: false)
            await stand.deliver(event)
            await stand.machine.tick(now: moment.addingTimeInterval(120))

            let afterFailure = await stand.machine.sessions()
            XCTAssertTrue(afterFailure.isEmpty, "отмена \(isCancelled): сессия терминальна")
            XCTAssertEqual(stand.meetings.storedRecords.first?.status, .failed)
            await stand.machine.stop()
        }
    }

    // MARK: - К65 (§8.7, `summarize`)

    /// `summarize` не ставится НИ РАЗУ: обработчик её в Срезе 1 не зарегистрирован, и задача
    /// повисла бы в очереди навсегда.
    func test_k65_summarizeIsNeverSubmitted() async throws {
        let (stand, _, recordingId, ids) = try await processing()
        _ = try await stand.repositories.transcripts.save(
            try SessionMachineFixtures.transcript(recordingId: recordingId)
        )
        try await runChain(stand, recordingId: recordingId, ids: ids, upTo: 3)
        stand.queue.setJobs([SessionMachineFixtures.job(
            id: ids[3], payload: .attribute(transcriptId: UUID(), meetingId: nil)
        )])
        await stand.deliver(JobEvent.succeeded(jobId: ids[3], type: .attribute))
        await stand.machine.tick(now: moment.addingTimeInterval(150))

        XCTAssertEqual(stand.queue.submissions.count, 4, "пятой задачи нет")
        XCTAssertFalse(
            stand.queue.submissions.map(\.payload.type).contains(.summarize),
            "`summarize` не ставится ни разу"
        )
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .ready, "и сессия ушла в `ready`")
        await stand.machine.stop()
    }

    // MARK: - К66 (§8.7, повторная обработка сессию не оживляет)

    /// Сессия в `failed` остаётся в `failed`: строка 14 из терминального состояния не
    /// срабатывает, и `setStatus` в `ready` машина не зовёт.
    func test_k66_aRepeatedProcessingDoesNotReviveATerminalSession() async throws {
        let (stand, _, recordingId, ids) = try await processing()
        stand.queue.setJobs([SessionMachineFixtures.job(
            id: ids[0], payload: .transcode(recordingId: recordingId)
        )])
        await stand.deliver(JobEvent.failed(
            jobId: ids[0], type: .transcode, error: "битый файл", willRetry: false
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(120))
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .failed)

        // Человек починил обработку сам: задачи заведены заново и дошли до `attribute`.
        let statusCalls = stand.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)")
        await stand.deliver(JobEvent.succeeded(jobId: ids[0], type: .attribute))
        await stand.machine.tick(now: moment.addingTimeInterval(130))

        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .failed, "сессия осталась в `failed`")
        XCTAssertEqual(
            stand.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)"),
            statusCalls,
            "`setStatus` в `ready` не зван ни разу"
        )
        await stand.machine.stop()
    }
}
