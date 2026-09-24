//  Восстановление §10, перечень А по записям — К77 целиком (издание v8).
//  MEE-307, часть C; правка по возврату РП — MEE-341. Пункты плана MEE-288 §3, разделы И
//  и Л, часть 5/8. К92 и вид 3 К46 вынесены в `SessionMachineChainRecoveryTests.swift` —
//  механически, файл длиннее четырёхсот строк нарушает `--strict` линта.
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
            XCTAssertEqual(
                stand.log.count(port: "AudioCapturePort", method: "recover(directory:)"), 0,
                "\(label): `recover` не зовётся на записи, уже стоящей в `.failed`"
            )
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

    /// РАЗЛИЧАЮЩИЙ ВЕКТОР ПЛАНА `АА` №3 (правка по возврату РП): `.finalized` с отказавшей
    /// либо отменённой задачей цепочки — сессия входит в `failed`, а не в `processing`
    /// (§8.7; тот же исход, что даёт строка 15 живой машине); дошедшая `attribute` —
    /// сессии нет ни одной. `recoverFinalized` для ad-hoc-записей (виды (ii) и (iii)) стал
    /// достижим впервые изданием v8 — до него источника для `.finalized` без сессии не
    /// было ни одного (находка 1, MEE-307), и этот путь был живым кодом без теста. Перебор
    /// — по обоим видам, отдельно от исчерпывающей матрицы выше: там журнал задач пуст
    /// всегда, а этот вектор — про НЕПУСТОЙ журнал.
    func test_k77_finalizedWithANonEmptyChainJournalForVidsIiAndIii() async throws {
        for kind in [OriginKind.originallyAdHoc, .orphanedByCascade] {
            try await assertFinalizedEntersFailed(kind: kind, jobStatus: .failed)
            try await assertFinalizedEntersFailed(kind: kind, jobStatus: .cancelled)
            try await assertFinalizedWithSucceededAttributeOpensNoSession(kind: kind)
        }
    }

    private func standForFinalizedVector(
        kind: OriginKind, recordingId: UUID
    ) async throws -> SessionMachineBench {
        let stand = try bench()
        let meetingId = kind == .originallyAdHoc ? nil : UUID()
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: meetingId)
        stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .finalized)])
        if let meetingId, kind == .orphanedByCascade {
            stand.seed(try SessionMachineFixtures.event(id: meetingId), status: .scheduled)
            try await stand.repositories.meetings.delete(meetingIds: [meetingId])
        }
        return stand
    }

    private func assertFinalizedEntersFailed(kind: OriginKind, jobStatus: JobStatus) async throws {
        let recordingId = UUID()
        let stand = try await standForFinalizedVector(kind: kind, recordingId: recordingId)
        stand.queue.setJobs([
            SessionMachineFixtures.job(
                id: UUID(), payload: .transcode(recordingId: recordingId), status: jobStatus
            )
        ])
        let label = "\(kind)/\(jobStatus)"
        let stream = stand.machine.changes()

        await stand.machine.start(now: moment)

        let published = await collect(stream, count: 1)
        let session = try unwrap(published.first?.session, label)
        XCTAssertEqual(session.state, .failed, "\(label): задача \(jobStatus) — сессия входит в `failed`")
        XCTAssertEqual(session.recordingId, recordingId, "\(label): и несёт номер той самой записи")
        await stand.machine.stop()
    }

    private func assertFinalizedWithSucceededAttributeOpensNoSession(kind: OriginKind) async throws {
        let recordingId = UUID()
        let stand = try await standForFinalizedVector(kind: kind, recordingId: recordingId)
        _ = try await stand.repositories.transcripts.save(
            try SessionMachineFixtures.transcript(recordingId: recordingId)
        )
        let header = try unwrap(try await stand.repositories.transcripts.latest(recordingId: recordingId))
        stand.queue.setJobs([
            SessionMachineFixtures.job(
                id: UUID(), payload: .attribute(transcriptId: header.id, meetingId: nil), status: .succeeded
            )
        ])
        let label = "\(kind)/attribute succeeded"

        await stand.machine.start(now: moment)

        let sessions = await stand.machine.sessions()
        XCTAssertTrue(sessions.isEmpty, "\(label): дошедшая `attribute` — сессии нет ни одной")
        await stand.machine.stop()
    }
}
