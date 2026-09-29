//  Отказ каталога записи на входе в `recording` — MEE-447 (приёмка РП по MEE-440).
//
//  `SessionMachine.recordingDirectory` — `async throws`, и отказ создания каталога доходит
//  до `enterRecording` (`SessionMachineRecording.swift`) ПРЕЖДЕ `capture.start`. Тест
//  проверяет, что этот отказ ничего не начинает: захват не зван, токен питания не взят,
//  очередь о записи не узнала, переход не записан, а наружу идёт та же ошибка хранилища.
//
//  Машина настоящая, порты — фейки стенда `SessionMachineBench`; фейк координатора сессий
//  здесь не нужен и не упоминается (страж К88).

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineRecordingDirectoryTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    /// Сессия `awaitingSignal` с звучащей целью при политике `manual`: сама машина не пишет,
    /// и вход в `recording` даёт только команда `startRecording` (строка 8).
    func test_mee447_recordingDirectoryFailureStartsNothingAndRethrowsStorageError() async throws {
        let failure = StorageError.io(message: "каталог записи не создан")
        let stand = SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: .manual),
            weights: try SessionMachineFixtures.weights(),
            recordingDirectory: { _ in throw failure }
        )
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let before = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(before.state, .awaitingSignal, "вектор непустоты: до команды сессия ждёт")
        XCTAssertNil(before.recordingId)
        let storedBefore = stand.meetings.storedRecords.first?.status
        let setStatusBefore = stand.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)")

        do {
            _ = try await stand.machine.startRecording(meetingId: event.id, now: moment.addingTimeInterval(70))
            XCTFail("ожидался отказ каталога записи")
        } catch let error as StorageError {
            XCTAssertEqual(error, failure, "наружу — та же ошибка хранилища, не обёрнутая")
        } catch {
            XCTFail("неожиданный тип ошибки: \(error)")
        }

        XCTAssertEqual(
            stand.capture.callCount(of: { if case .start = $0 { return true }; return false }), 0,
            "capture.start не зван: каталога нет — запрашивать захват нечем"
        )
        XCTAssertEqual(stand.power.beginActivityCallCount, 0, "токен питания не взят")
        XCTAssertTrue(stand.power.liveActivities.isEmpty, "и живых токенов нет")
        XCTAssertEqual(stand.queue.recordingDidStartCallCount, 0, "очередь о записи не узнала")

        XCTAssertEqual(
            stand.log.count(port: "MeetingRepository", method: "setStatus(_:meetingId:)"), setStatusBefore,
            "переход в `recording` не записан"
        )
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, storedBefore, "хранимый статус прежний")
        let after = try unwrap(await stand.machine.session(id: before.sessionId))
        XCTAssertEqual(after.state, .awaitingSignal, "статус сессии прежний")
        XCTAssertNil(after.recordingId, "инвариант 5: вне `recording` `recordingId == nil`")
        await stand.machine.stop()
    }
}
