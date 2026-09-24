//  Восстановление §10, перечень А по записям — К77, К92 и вид 3 К46.
//  MEE-307, часть C. Пункты плана MEE-288 §3, разделы И и Л, часть 5/8.
//
//  ЧТО ЗДЕСЬ НАБЛЮДАЕТСЯ ПОРЯДКОМ ВЫЗОВОВ, А НЕ КОНЕЧНЫМ СОСТОЯНИЕМ: К77 требует, чтобы
//  `save(.finalized)` предшествовал и входу в `processing`, и постановке задачи. Конечное
//  состояние у верной и у неверной реализации здесь совпадает, и различает их только
//  журнал (`PortCallLog`, условие `Н` плана MEE-288 §2).

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineRecoveryTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К77 (§10, перечень А; инв. 22, целиком — источник и `origin` под издание v8)

    /// Три вида происхождения записи (издание v8): (i) непустой `meeting_id`, встреча
    /// существует; (ii) `meeting_id` пуст с рождения записи; (iii) встреча удалена, колонка
    /// обнулена каскадом (C-010, инвариант 7) — доменными средствами неотличим от (ii)
    /// (инвариант 29) и не обязан различаться этим методом, но оснастка теста собирает его
    /// отдельно, чтобы поймать реализацию, читающую `origin` из `manifest.meetingId`.
    private enum OriginKind: CaseIterable {
        case scheduledExisting
        case originallyAdHoc
        case orphanedByCascade
    }

    /// `.recording` и `.stopping`: `recover` удался — запись приводится к `.finalized`
    /// ПРЕЖДЕ входа в `processing` и ПРЕЖДЕ постановки задачи. Порядок наблюдается журналом
    /// вызовов, а не конечным состоянием (К77), и виду происхождения он не зависит —
    /// `recoverInterrupted` зовёт `recover`/`save`/`submit` в этом порядке при любом
    /// `isAdHoc`, и потому проверен здесь один раз, а не перебором по видам.
    func test_k77_recoveringStatusesFinalizeTheRecordBeforeEnteringProcessing() async throws {
        for status in [RecordingStatus.recording, .stopping] {
            let stand = try bench()
            let recordingId = UUID()
            let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: nil)
            stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: status)])
            stand.capture.setRecoverManifest(manifest)

            await stand.machine.start(now: moment)

            let saved = stand.repositories.recordings.storedRecords
            XCTAssertEqual(saved.first?.status, .finalized, "\(status): запись приведена к `.finalized`")
            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.state, .processing, "\(status): сессия вошла в `processing`")
            XCTAssertEqual(live.recordingId, recordingId, "и несёт номер той самой записи")
            XCTAssertEqual(live.origin, .adHoc, "отдана `adHoc()` (нет привязки к встрече) → `.adHoc`")
            XCTAssertNil(live.meetingId, "инвариант 4 первой половиной")

            XCTAssertTrue(
                stand.log.happened("AudioCapturePort.recover(directory:)", before: "RecordingRepository.save(_:)"),
                "\(status): `recover` прежде сохранения"
            )
            XCTAssertTrue(
                stand.log.happened("RecordingRepository.save(_:)", before: "JobQueue.submit(_:)"),
                "\(status): сохранение прежде постановки задачи"
            )
            await stand.machine.stop()
        }
    }

    /// `recover` бросил — запись приводится к `.failed`, сессия входит в `failed`, задача
    /// не ставится ни одна; `origin` тем же правилом, что и на удавшемся `recover`.
    func test_k77_aFailedRecoveryLeadsToFailedRecordAndFailedSession() async throws {
        let stand = try bench()
        let recordingId = UUID()
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: nil)
        stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .recording)])
        stand.capture.failRecover(with: .recoveryFailed(
            directoryName: recordingId.uuidString, message: "вектор"
        ))
        let stream = stand.machine.changes()

        await stand.machine.start(now: moment)

        XCTAssertEqual(
            stand.repositories.recordings.storedRecords.first?.status, .failed,
            "запись приведена к `.failed`"
        )
        // Сессия терминальна, и `sessions()` терминальных не отдаёт (§3.1): наблюдается она
        // снимком в `changes()` — тем единственным, который перечень А публикует.
        let published = await collect(stream, count: 1)
        let session = try unwrap(published.first?.session)
        XCTAssertEqual(session.state, .failed, "сессия вошла в `failed`")
        XCTAssertEqual(session.recordingId, recordingId, "и несёт номер той самой записи")
        XCTAssertEqual(session.origin, .adHoc, "отдана `adHoc()` → `.adHoc`, тем же правилом, что и удача")
        XCTAssertEqual(stand.queue.submissions.count, 0, "задача не ставится ни одна")
        await stand.machine.stop()
    }

    /// Перебор × трём видам происхождения порознь. `RecordingStatus` объявлен в другом
    /// модуле (`DomainCore`) без `CaseIterable`, и ретроактивная синтеза `allCases` через
    /// модульную границу компилятором не выполняется (проверено — CI отвечал: «extension
    /// outside of file declaring enum prevents automatic synthesis»); литерал ниже —
    /// именно поэтому явный список, а не `allCases`. Полноту перебора вместо него держит
    /// исчерпывающий `switch` без `default` внутри `assertListA` (четыре случая, ни одного
    /// лишнего): добавление значения `RecordingStatus` ломает СБОРКУ этого `switch`-а, а не
    /// расширяет перебор молча, — и это тот же эффект, которого искал бы `allCases`.
    func test_k77_everyRecordingStatusTimesEveryOriginKindAnswersAsListA() async throws {
        for status in [RecordingStatus.recording, .stopping, .finalized, .failed] {
            for kind in OriginKind.allCases {
                try await assertListA(status: status, kind: kind)
            }
        }
    }

    /// Вход и ответ перечня А (издание v8) для одной пары (`RecordingStatus`, вид
    /// происхождения). Меет `.recording` у сопутствующей встречи, помимо (ii), — техническая
    /// деталь оснастки: она держит вид (i) на всех четырёх статусах вне ветки перечня Б
    /// «заводить заново» (§9.1), не влияя на РЕШЕНИЕ перечня А, которое читает запись, а не
    /// статус встречи.
    private func assertListA(status: RecordingStatus, kind: OriginKind) async throws {
        let stand = try bench()
        let recordingId = UUID()
        let meetingId = kind == .originallyAdHoc ? nil : UUID()
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: meetingId)
        stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: status)])
        if let meetingId, kind == .scheduledExisting {
            stand.seed(try SessionMachineFixtures.event(id: meetingId), status: .recording)
        }
        if let meetingId, kind == .orphanedByCascade {
            stand.seed(try SessionMachineFixtures.event(id: meetingId), status: .scheduled)
            try await stand.repositories.meetings.delete(meetingIds: [meetingId])
        }
        stand.capture.setRecoverManifest(manifest)
        let label = "\(status)/\(kind)"

        switch status {
        case .recording, .stopping:
            await stand.machine.start(now: moment)
            let live = try unwrap(await stand.machine.sessions().first { $0.recordingId == recordingId }, label)
            XCTAssertEqual(live.state, .processing, "\(label): удавшийся `recover` вводит в `processing`")
            assertOrigin(live, kind: kind, meetingId: meetingId, label: label)
        case .failed:
            await stand.machine.start(now: moment)
            let sessions = await stand.machine.sessions()
            XCTAssertTrue(sessions.isEmpty, "\(label): `.failed` терминален для перечня А на любом виде")
        case .finalized:
            await stand.machine.start(now: moment)
            let live = try unwrap(await stand.machine.sessions().first { $0.recordingId == recordingId }, label)
            XCTAssertEqual(
                live.state, .processing,
                "\(label): `.finalized` без дошедшей `attribute` и без отказавшей/отменённой задачи — `processing`"
            )
            assertOrigin(live, kind: kind, meetingId: meetingId, label: label)
        }
        await stand.machine.stop()
    }

    private func assertOrigin(_ live: SessionSnapshot, kind: OriginKind, meetingId: UUID?, label: String) {
        switch kind {
        case .scheduledExisting:
            XCTAssertEqual(live.origin, .scheduled, "\(label): вид (i), не отдана `adHoc()` → `.scheduled`")
            XCTAssertEqual(live.meetingId, meetingId, "\(label): и `meetingId`, равный `manifest.meetingId`")
        case .originallyAdHoc, .orphanedByCascade:
            XCTAssertEqual(
                live.origin, .adHoc,
                "\(label): виды (ii) и (iii) отданы `adHoc()` одинаково → `.adHoc`"
            )
            XCTAssertNil(
                live.meetingId,
                "\(label): `meetingId == nil`, несмотря на непустой `manifest.meetingId` у вида (iii)"
            )
        }
    }

    /// РАЗЛИЧАЮЩИЙ ВЕКТОР ИЗДАНИЯ v4: два `start(now:)` подряд на одной и той же записи.
    /// После первого запись стоит в `.finalized`; второй `recover` на ней НЕ ЗОВЁТ и из
    /// `unfinalized()` её не получает. Реализация, оставляющая строку в `.recording`, этот
    /// вектор проваливает, а по базовой редакции была бы зелена.
    func test_k77_theV4DistinguishingVectorTwoStartsOnTheSameRecord() async throws {
        let stand = try bench()
        let recordingId = UUID()
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: nil)
        stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .recording)])
        stand.capture.setRecoverManifest(manifest)

        await stand.machine.start(now: moment)
        await stand.machine.stop()
        let afterFirst = stand.log.count(port: "AudioCapturePort", method: "recover(directory:)")

        let second = try bench()
        second.repositories.recordings.seed(stand.repositories.recordings.storedRecords)
        second.capture.setRecoverManifest(manifest)
        await second.machine.start(now: moment)

        XCTAssertEqual(afterFirst, 1, "первый запуск зовёт `recover` ровно раз")
        XCTAssertEqual(
            second.log.count(port: "AudioCapturePort", method: "recover(directory:)"), 0,
            "второй запуск `recover` не зовёт: запись уже `.finalized`"
        )
        await second.machine.stop()
    }

    // MARK: - К92 (инвариант 20, вторая половина; §8.7, второй пункт)

    /// Вход (ii): восстановительный вход ставит РОВНО ОДНУ задачу — первую по порядку
    /// цепочки, у которой у этой записи нет ни успешно завершённой, ни ждущей, ни идущей.
    /// Недошедшей делается ПООЧЕРЁДНО каждая из четырёх.
    func test_k92_ii_theRestoringEntrySubmitsExactlyTheFirstUnreachedJob() async throws {
        let chain: [JobType] = [.transcode, .transcribe, .diarize, .attribute]
        for (index, expected) in chain.enumerated() {
            let stand = try bench()
            let recordingId = UUID()
            let manifest = try SessionMachineFixtures.manifest(
                recordingId: recordingId, meetingId: nil
            )
            stand.repositories.recordings.seed([
                RecordingRecord(manifest: manifest, status: .recording)
            ])
            stand.capture.setRecoverManifest(manifest)
            // Транскрипт нужен, чтобы `attribute` строилась и опознавалась (К63).
            _ = try await stand.repositories.transcripts.save(
                try SessionMachineFixtures.transcript(recordingId: recordingId)
            )
            let header = try unwrap(
                try await stand.repositories.transcripts.latest(recordingId: recordingId)
            )
            stand.queue.setJobs(chain.prefix(index).map { type in
                SessionMachineFixtures.job(
                    id: UUID(),
                    payload: payload(type, recordingId: recordingId, transcriptId: header.id)
                )
            })

            await stand.machine.start(now: moment)

            XCTAssertEqual(
                stand.queue.submissions.count, 1,
                "\(expected): поставлена РОВНО ОДНА задача, а не цепочка целиком и не ноль"
            )
            XCTAssertEqual(
                stand.queue.submissions.first?.payload.type, expected,
                "\(expected): и это первая недошедшая"
            )
            await stand.machine.stop()
        }
    }

    /// Вход (iii), третье место — перебором: ни один из этих входов задачи не ставит,
    /// включая ПОВТОРНЫЙ `start(now:)` на той же записи.
    func test_k92_iii_noThirdPlaceSubmitsAJob() async throws {
        let stand = try bench()
        let recordingId = UUID()
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: nil)
        stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .recording)])
        stand.capture.setRecoverManifest(manifest)

        await stand.machine.start(now: moment)
        let afterStart = stand.queue.submissions.count
        XCTAssertEqual(afterStart, 1, "оснастка: восстановительный вход поставил одну задачу")

        await stand.machine.tick(now: moment.addingTimeInterval(30))
        await stand.deliver(JobEvent.blocked(jobId: UUID(), type: .transcode, reason: .notYetDue))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.deliver(JobEvent.failed(
            jobId: UUID(), type: .transcode, error: "вектор", willRetry: true
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(90))
        await stand.deliver(PowerEvent.didWake)
        await stand.machine.tick(now: moment.addingTimeInterval(120))
        await stand.machine.start(now: moment.addingTimeInterval(150))

        XCTAssertEqual(
            stand.queue.submissions.count, afterStart,
            "третьего входа нет ни одного: ни `tick`, ни `blocked`, ни `failed(willRetry:)`, "
                + "ни `didWake`, ни повторный `start`"
        )
        await stand.machine.stop()
    }

    // MARK: - К46, вид 3 (порядок «заведение против сроков», издание v6)

    /// `start(now:)` НЕ ИСПОЛНЯЕТ НИ ОДНОГО СРОКА. Хранилище, в котором у сессии, заводимой
    /// перечнем Б, срок УЖЕ НАСТУПИЛ: встреча в `awaitingSignal` при `now == graceEndsAt`.
    /// Между возвратом `start(now:)` и первым `tick` сессия наблюдается в `awaitingSignal`,
    /// и снимок этот ВЕРЕН; в `skipped` она уходит ПЕРВЫМ `tick` строкой 9.
    ///
    /// РАЗЛИЧАЮЩИЙ ВЕКТОР: реализация, исполняющая сроки внутри `start`, публикует здесь
    /// ОДИН снимок вместо ДВУХ.
    func test_k46_iii_startExecutesNoDeadlineAndTheFirstTickDoes() async throws {
        let stand = try bench()
        let settings = SessionMachineFixtures.settings()
        let event = try SessionMachineFixtures.event(
            start: moment.addingTimeInterval(-TimeInterval(settings.missingSignalGraceSeconds))
        )
        stand.seed(event, status: .awaitingSignal)
        let arm = SessionMachineRules.arm(for: event, settings: settings)
        XCTAssertEqual(arm.graceEndsAt, moment, "оснастка: `now == graceEndsAt`")

        let stream = stand.machine.changes()
        await stand.machine.start(now: moment)

        let between = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(
            between.state, .awaitingSignal,
            "между `start` и первым `tick` сессия стоит в `awaitingSignal` при наступившем сроке"
        )
        await stand.machine.tick(now: moment)
        let after = await stand.machine.session(id: between.sessionId)
        XCTAssertEqual(after?.state, .skipped, "в `skipped` уводит ПЕРВЫЙ `tick` строкой 9")

        let published = await collect(stream, count: 2)
        XCTAssertEqual(
            published.compactMap { $0.session?.state }, [.awaitingSignal, .skipped],
            "снимков ДВА, а не один: заведение и срок — разные ходы"
        )
        await stand.machine.stop()
    }

    // MARK: - Оснастка

    /// Нагрузка звена цепочки — та же, что строит машина (§8.7).
    private func payload(_ type: JobType, recordingId: UUID, transcriptId: UUID) -> JobPayload {
        switch type {
        case .transcode:
            return .transcode(recordingId: recordingId)
        case .transcribe:
            return .transcribe(recordingId: recordingId, profileId: "profile-1", language: nil)
        case .diarize:
            return .diarize(recordingId: recordingId, profileId: "profile-1")
        case .attribute:
            return .attribute(transcriptId: transcriptId, meetingId: nil)
        case .summarize:
            return .summarize(meetingId: UUID(), transcriptId: transcriptId, profileId: "profile-1")
        }
    }
}
