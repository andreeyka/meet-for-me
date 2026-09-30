//  Сквозной тест «машина + настоящая очередь» (MEE-498, из ревью #207/MEE-489): цепочка C-018
//  §8.7 `transcode → transcribe → diarize → attribute` доходит до конца сама — следующую задачу
//  машина ставит по `JobEvent.succeeded` предыдущей, опубликованному `JobQueueEngine`, а не
//  событием, поданным тестом. Прочие тесты цепочки (`SessionMachineChainTests`) стоят на
//  `FakeJobQueue` и события подают руками — они не видят, согласованы ли машина и очередь:
//  нагрузка, которую отдаёт `job(id:)`, условия `JobSubmission.standard` (профиль, питание, запись)
//  и регистрация всех четырёх обработчиков, включая пустышки `transcode`/`diarize` (C-013 v16).
//
//  ВРЕМЯ. Машина часов не имеет (C-018, К9): пришедшие события она применяет своим `tick`, и
//  тест зовёт `tick` сам, пока встреча не станет `ready`. Событие очереди доходит до ящика машины
//  через отдельную задачу подписки, поэтому ход повторяется, а не считается; предел — только
//  страховка от зависания, ни одно утверждение на нём не стоит.
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineRealQueueChainTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private struct Rig {
        let processes = FakeProcessMonitorPort()
        let capture = FakeAudioCapturePort()
        let repositories = InMemoryRepositories()
        let jobs = InMemoryJobRepository()
        let transcription = FakeTranscriptionServicePort()
        let attribute = FakeJobHandler(type: .attribute)
        let queue: JobQueueEngine
        let machine: SessionMachine

        init(clockNow: Date) throws {
            let clock = ManualClock(now: clockNow)
            queue = JobQueueEngine(
                repository: jobs, modelCatalog: StubModelCatalogPort(),
                powerPort: FakePowerPort(snapshot: SessionMachineFixtures.powerSnapshot),
                clock: { clock.now() }
            )
            machine = SessionMachine(
                processes: processes, calendar: FakeCalendarPort(), meetings: repositories.meetings,
                recordings: repositories.recordings, transcripts: repositories.transcripts, capture: capture,
                queue: queue, power: FakePowerPort(snapshot: SessionMachineFixtures.powerSnapshot),
                settings: SessionMachineFixtures.settings(policy: .auto),
                weights: try SessionMachineFixtures.weights(),
                recordingDirectory: SessionMachineFixtures.recordingDirectory,
                captureInput: SessionMachineFixtures.captureInput,
                systemFormat: SessionMachineFixtures.systemFormat, micFormat: SessionMachineFixtures.micFormat
            )
        }

        func registerHandlers() async throws {
            try await queue.register(handler: TranscodeJobHandler())
            try await queue.register(handler: TranscribeJobHandler(
                port: transcription, transcripts: repositories.transcripts
            ))
            try await queue.register(handler: DiarizeJobHandler())
            try await queue.register(handler: attribute)
        }

        func deliver(_ signal: MeetingSignal) async {
            let before = await machine.mailbox.receivedCount
            processes.emit(signal)
            await machine.mailbox.waitUntilReceived(before + 1)
        }

        func deliver(_ event: CaptureEvent) async {
            let before = await machine.mailbox.receivedCount
            capture.emit(event)
            await machine.mailbox.waitUntilReceived(before + 1)
        }
    }

    /// Встреча записана и остановлена строкой 12, машина в `processing` поставила `transcode` в
    /// настоящую очередь. Возвращает `recordingId` записи.
    private func stageProcessing(_ rig: Rig, event: MeetingEvent) async throws -> UUID {
        rig.repositories.meetings.seed([MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: [])])
        rig.capture.setStartResult(CaptureStarted(
            recordingId: UUID(), startedAt: moment, tracks: [], captureGroupKey: nil
        ))
        rig.capture.setStopManifest(RecordingManifestFixtures.unfinished)

        await rig.machine.start(now: moment.addingTimeInterval(60))
        await rig.machine.tick(now: moment.addingTimeInterval(60))
        await rig.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
        ))
        await rig.machine.tick(now: moment.addingTimeInterval(60))
        let live = try unwrap(await rig.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "оснастка: сессия в записи")
        let recordingId = try XCTUnwrap(live.recordingId)
        rig.transcription.forcedResult = { try SessionMachineFixtures.transcript(recordingId: recordingId) }

        try await rig.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(70))
        await rig.deliver(CaptureEvent.stopped(
            try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: event.id)
        ))
        await rig.machine.tick(now: moment.addingTimeInterval(80))
        let status = try await rig.repositories.meetings.meeting(id: event.id)?.status
        XCTAssertEqual(status, .processing, "оснастка: сессия в обработке")
        return recordingId
    }

    /// Ходы машины, пока встреча не станет `ready` (или не кончится страховочный предел).
    /// Между ходами очередь дорабатывает поставленное, а событие её доходит до ящика машины.
    private func tickUntilReady(_ rig: Rig, meetingId: UUID) async throws -> MeetingStatus? {
        var status = try await rig.repositories.meetings.meeting(id: meetingId)?.status
        var step = 0
        while status != .ready, step < 500 {
            step += 1
            await rig.queue.waitUntilIdle()
            try await Task.sleep(nanoseconds: 10_000_000)
            await rig.machine.tick(now: moment.addingTimeInterval(80 + Double(step)))
            status = try await rig.repositories.meetings.meeting(id: meetingId)?.status
        }
        return status
    }

    /// Цепочка §8.7 целиком на настоящей очереди: тест не подаёт ни одного `JobEvent`.
    func test_chainReachesAttributeOnRealQueueBySucceededEventsAlone() async throws {
        let rig = try Rig(clockNow: moment.addingTimeInterval(3_600))
        try await rig.registerHandlers()
        await rig.queue.start()
        let event = try SessionMachineFixtures.event()
        let recordingId = try await stageProcessing(rig, event: event)

        let status = try await tickUntilReady(rig, meetingId: event.id)

        XCTAssertEqual(status, .ready, "цепочка дошла до успешной `attribute`")
        let succeeded = try await rig.queue.jobs(status: .succeeded)
        XCTAssertEqual(
            succeeded.map(\.type.rawValue).sorted(),
            ["attribute", "diarize", "transcode", "transcribe"], "каждое звено — ровно одна задача"
        )
        let failed = try await rig.queue.jobs(status: .failed)
        let pending = try await rig.queue.jobs(status: .pending)
        XCTAssertTrue(failed.isEmpty, "\(failed)")
        XCTAssertTrue(pending.isEmpty, "\(pending)")
        let transcriptId = try unwrap(try await rig.repositories.transcripts.latest(recordingId: recordingId)?.id)
        XCTAssertEqual(
            rig.attribute.observedJobs.map(\.payload), [.attribute(transcriptId: transcriptId, meetingId: event.id)],
            "`attribute` — по транскрипту, сохранённому настоящим `TranscribeJobHandler`"
        )

        await rig.machine.stop()
        await rig.queue.stop()
    }
}
