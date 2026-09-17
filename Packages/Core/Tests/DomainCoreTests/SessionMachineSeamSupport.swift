//  Оснастка перепроверки шва A/B: проход сессии по всей цепочке до `ready`.
//  MEE-300, часть B.
//
//  Вынесено из тестов по одному доводу, и он не про красоту: оба файла перепроверки
//  (`SessionMachineSeamTests` и `SessionMachineSeamOrderTests`) ведут сессию одним и тем же
//  путём, а два его описания разошлись бы на первой же правке — ровно тот класс, который
//  правила проекта называют «второе определение одного термина».

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

/// Всё, что даёт проход до `ready`: стенд, событие, `sessionId` и `recordingId`.
/// Значение, а не кортеж из четырёх: сессия к этой минуте терминальна, и `sessions()` её
/// уже не отдаёт — читать её приходится по `session(id:)`.
struct SessionMachineWholeWay {

    let stand: SessionMachineBench
    let event: MeetingEvent
    let sessionId: UUID
    let recordingId: UUID
    let jobIds: [UUID]

    /// Сессия встречи, проведённая до `ready`: `awaitingSignal` → `recording` → `stopping`
    /// → `processing` → `ready`, по строкам 8, 10, 12 и 14.
    static func build(from moment: Date) async throws -> SessionMachineWholeWay {
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

        try await stand.machine.stopRecording(
            recordingId: recordingId, now: moment.addingTimeInterval(70)
        )
        let manifest = try SessionMachineFixtures.manifest(
            recordingId: recordingId, meetingId: event.id
        )
        await stand.deliver(CaptureEvent.stopped(manifest))
        await stand.machine.tick(now: moment.addingTimeInterval(80))

        _ = try await stand.repositories.transcripts.save(
            try SessionMachineFixtures.transcript(recordingId: recordingId)
        )
        await runChain(stand, recordingId: recordingId, ids: ids, from: moment)
        return SessionMachineWholeWay(
            stand: stand,
            event: event,
            sessionId: live.sessionId,
            recordingId: recordingId,
            jobIds: ids
        )
    }

    /// Цепочка §8.7 до конца: на каждый `succeeded` предыдущей машина ставит следующую,
    /// а `succeeded` задачи `attribute` уводит сессию в `ready` строкой 14.
    private static func runChain(
        _ stand: SessionMachineBench,
        recordingId: UUID,
        ids: [UUID],
        from moment: Date
    ) async {
        let payloads: [JobPayload] = [
            .transcode(recordingId: recordingId),
            .transcribe(recordingId: recordingId, profileId: "profile-1", language: nil),
            .diarize(recordingId: recordingId, profileId: "profile-1")
        ]
        for index in 0..<3 {
            stand.queue.setJobs([SessionMachineFixtures.job(id: ids[index], payload: payloads[index])])
            await stand.deliver(JobEvent.succeeded(jobId: ids[index], type: payloads[index].type))
            await stand.machine.tick(now: moment.addingTimeInterval(90 + Double(index)))
        }
        await stand.deliver(JobEvent.succeeded(jobId: ids[3], type: .attribute))
        await stand.machine.tick(now: moment.addingTimeInterval(100))
    }
}
