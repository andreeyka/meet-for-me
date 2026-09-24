//  MEE-357 (IR-121, MEE-356, C-013 v9): SessionMachine сообщает JobQueue о факте идущей
//  записи — единственные два места, где домен достоверно знает начало и конец записи
//  (`enterRecording`/`enterStopping`, `SessionMachineRecording.swift`), рядом с уже
//  существующими вызовами `capture.start()`/`capture.stop()`.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineJobQueueSignalTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    func test_mee357_recordingDidStartIsCalledOnceEnteringRecording() async throws {
        let staged = try await SessionMachineStand.recording(from: moment)
        XCTAssertEqual(staged.stand.queue.recordingDidStartCallCount, 1, "ровно один вызов на вход в recording")
        XCTAssertEqual(staged.stand.queue.recordingDidStopCallCount, 0, "стоп ещё не звался")
        await staged.stand.machine.stop()
    }

    func test_mee357_recordingDidStopIsCalledOnceEnteringStopping() async throws {
        let staged = try await SessionMachineStand.recording(from: moment)
        try await staged.stand.machine.stopRecording(
            recordingId: staged.recordingId, now: moment.addingTimeInterval(70)
        )
        XCTAssertEqual(staged.stand.queue.recordingDidStartCallCount, 1, "старт не задвоился")
        XCTAssertEqual(staged.stand.queue.recordingDidStopCallCount, 1, "ровно один вызов на вход в stopping")
        await staged.stand.machine.stop()
    }

    /// `enterStopping` зовёт `queue.recordingDidStop()` до попытки `capture.stop()`, а не
    /// после, — запись перестаёт числиться идущей вне зависимости от исхода самой остановки
    /// (строка 13, `stopping → failed`, К41 её не отменяет).
    func test_mee357_recordingDidStopIsCalledEvenWhenCaptureStopFails() async throws {
        let staged = try await SessionMachineStand.recording(from: moment)
        staged.stand.capture.failStop(with: .notRunning)
        try await staged.stand.machine.stopRecording(
            recordingId: staged.recordingId, now: moment.addingTimeInterval(70)
        )
        XCTAssertEqual(staged.stand.queue.recordingDidStopCallCount, 1, "вызван даже когда capture.stop() бросил")
        await staged.stand.machine.stop()
    }
}
