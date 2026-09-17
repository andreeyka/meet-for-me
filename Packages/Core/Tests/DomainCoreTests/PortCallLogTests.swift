//  MEE-290: журнал вызовов портов — условие `Н` плана MEE-288 §2.
//
//  ЧТО ЗДЕСЬ ПРОВЕРЯЕТСЯ И ПОЧЕМУ ИМЕННО ЭТО. Условие `Н` сказано так: «журнал вызовов портов
//  с сохранённым ПОРЯДКОМ… НЕ СЧЁТЧИК, А ПОСЛЕДОВАТЕЛЬНОСТЬ: К77 и К81 требуют „прежде“, а не
//  „оба случились“». Значит проверяемы ровно две вещи: что порядок сохраняется и что «прежде»
//  различает порядок, а не наличие. Первое ловит журнал на множестве, второе — журнал на
//  счётчиках.
//
//  ТРЕБОВАНИЕ К СОБСТВЕННОЙ НЕПУСТОТЕ ИСПОЛНЕНО ЯВНО. Тест, который считает и сравнивает,
//  зелен по построению на пустом журнале: ноль равен нулю, а «прежде» на отсутствующих
//  вызовах не нарушается никогда. Поэтому каждое место, где что-то считается, несёт рядом
//  вектор, краснеющий на пустоте, — `XCTAssertFalse(log.isEmpty)` и утверждение о ЧИСЛЕ
//  записей, а не только об их порядке. Основание — MEE-289, где четыре вектора из семи
//  проверяли сам разборщик, а не предмет.

import XCTest
import DomainCore
import DomainTestKit

final class PortCallLogTests: XCTestCase {

    // MARK: - Порядок сохраняется, и он поперёк портов

    func test_mee290_callLog_keepsOrderAcrossPorts() async throws {
        let log = PortCallLog()
        let repositories = InMemoryRepositories(log: log)
        let queue = FakeJobQueue(log: log)

        // Вектор непустоты: до вызовов журнал пуст, и утверждения ниже без них были бы
        // зелены по построению.
        XCTAssertTrue(log.isEmpty, "журнал начинается пустым")

        let record = RecordingRecord(manifest: RecordingManifestFixtures.hourlyTwoChannels, status: .finalized)
        try await repositories.recordings.save(record)
        log.mark("enter(processing)")
        _ = try await queue.submit(submission(.transcode(recordingId: record.manifest.recordingId)))

        XCTAssertEqual(
            log.signatures,
            ["RecordingRepository.save(_:)", "mark.enter(processing)", "JobQueue.submit(_:)"],
            "последовательность целиком, а не множество"
        )
        XCTAssertEqual(log.calls.count, 3, "записей ровно три — журнал не пуст и не переполнен")
        XCTAssertTrue(
            log.happened("RecordingRepository.save(_:)", before: "JobQueue.submit(_:)"),
            "порядок К77: сохранение прежде постановки"
        )
    }

    /// Журнал на счётчиках зелен там, где журнал на порядке красен. Это и есть причина, по
    /// которой условие `Н` требует последовательности, а не счёта.
    func test_mee290_callLog_orderIsNotDerivableFromCounts() async throws {
        let log = PortCallLog()
        let repositories = InMemoryRepositories(log: log)
        let queue = FakeJobQueue(log: log)

        // Порядок ОБРАТНЫЙ верному: сперва постановка, потом сохранение.
        _ = try await queue.submit(submission(.transcode(recordingId: UUID())))
        try await repositories.recordings.save(
            RecordingRecord(manifest: RecordingManifestFixtures.hourlyTwoChannels, status: .finalized)
        )

        // Счёт вызовов у верного и неверного порядка ОДИНАКОВ — вот вектор непустоты счётчика.
        XCTAssertEqual(log.count(port: "RecordingRepository", method: "save(_:)"), 1)
        XCTAssertEqual(log.count(port: "JobQueue", method: "submit(_:)"), 1)

        // А «прежде» их разводит.
        XCTAssertFalse(
            log.happened("RecordingRepository.save(_:)", before: "JobQueue.submit(_:)"),
            "обратный порядок не выдаётся за верный"
        )
        XCTAssertTrue(log.happened("JobQueue.submit(_:)", before: "RecordingRepository.save(_:)"))
    }

    // MARK: - «Прежде» на несостоявшемся вызове

    func test_mee290_callLog_happenedBeforeIsFalseWhenACallIsMissing() async throws {
        let log = PortCallLog()
        let repositories = InMemoryRepositories(log: log)
        try await repositories.recordings.save(
            RecordingRecord(manifest: RecordingManifestFixtures.hourlyTwoChannels, status: .finalized)
        )

        // Вектор непустоты: один вызов в журнале есть, и именно поэтому `false` ниже
        // говорит об отсутствии ВТОРОГО, а не о пустом журнале.
        XCTAssertEqual(log.calls.count, 1)
        XCTAssertFalse(
            log.happened("RecordingRepository.save(_:)", before: "JobQueue.submit(_:)"),
            "о несостоявшемся вызове «прежде» не утверждается"
        )
        XCTAssertNil(log.firstIndex(of: "JobQueue.submit(_:)"))
    }

    // MARK: - Аргументы и отбор по порту

    func test_mee290_callLog_recordsArgumentsAndFiltersByPort() async throws {
        let log = PortCallLog()
        let repositories = InMemoryRepositories(log: log)
        let meeting = MeetingEventFixtures.oneOnOneZoom
        repositories.meetings.seed([
            MeetingRecord(event: meeting, dedupKey: nil, status: .scheduled, sources: [])
        ])

        try await repositories.meetings.setStatus(.armed, meetingId: meeting.id)
        _ = try await repositories.meetings.meeting(id: meeting.id)

        let calls = log.calls(port: "MeetingRepository")
        XCTAssertEqual(calls.count, 2, "seed в журнал не пишется — он вход теста, а не вызов порта")
        XCTAssertEqual(calls.first?.method, "setStatus(_:meetingId:)")
        XCTAssertEqual(calls.first?.arguments, ["armed", meeting.id.uuidString])
        XCTAssertEqual(log.calls(port: "JobQueue"), [], "чужого порта в отборе нет")
    }

    func test_mee290_callLog_clearEmptiesIt() {
        let log = PortCallLog()
        log.record(port: "JobQueue", method: "start()")
        XCTAssertFalse(log.isEmpty, "вектор непустоты: очищать есть что")
        log.clear()
        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(log.signatures, [])
    }

    // MARK: - Оснастка

    private func submission(_ payload: JobPayload) -> JobSubmission {
        JobSubmission(
            payload: payload,
            priority: 0,
            maxAttempts: 3,
            runAfter: Date(timeIntervalSince1970: 0),
            conditions: JobConditions(
                requiresACPower: false,
                forbidWhileRecording: false,
                maxThermalPressure: .serious,
                requiresProfileReady: nil
            ),
            dedupKey: nil
        )
    }
}
