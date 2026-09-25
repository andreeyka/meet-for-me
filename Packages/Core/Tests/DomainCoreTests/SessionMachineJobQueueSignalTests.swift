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

    // MARK: - MEE-423 (IR-137, C-018 v11 инв. 25): строка 11 (`recording → failed`)

    /// `applyArrivedRows` зовёт `queue.recordingDidStop()` на строке 11, тем же приёмом, что
    /// `enterStopping` на строке 10 — прежде отсутствовавший вызов, флаг висел до перезапуска.
    func test_mee423_recordingDidStopIsCalledOnceEnteringFailedViaRow11() async throws {
        let staged = try await SessionMachineStand.recording(from: moment)
        await staged.stand.deliver(CaptureEvent.failed(.systemUnavailable(message: "отказ")))
        await staged.stand.machine.tick(now: moment.addingTimeInterval(80))

        let live = try unwrap(await staged.stand.machine.session(id: staged.sessionId))
        XCTAssertEqual(live.state, .failed, "строка 11: recording → failed")
        XCTAssertEqual(staged.stand.queue.recordingDidStartCallCount, 1, "старт не задвоился")
        XCTAssertEqual(staged.stand.queue.recordingDidStopCallCount, 1, "ровно один вызов на строку 11")
        await staged.stand.machine.stop()
    }

    /// `recordingDidStop()` зовётся ДО записи перехода и независимо от её исхода — запись
    /// уже остановилась сама (`CaptureEvent.failed`), и отказ записи это не меняет.
    func test_mee423_recordingDidStopIsCalledEvenWhenRow11TransitionWriteFails() async throws {
        let staged = try await SessionMachineStand.recording(from: moment)
        staged.stand.meetings.fail(with: .io(message: "запись перехода не удалась"), on: .setStatus)

        await staged.stand.deliver(CaptureEvent.failed(.systemUnavailable(message: "отказ")))
        await staged.stand.machine.tick(now: moment.addingTimeInterval(80))

        let live = try unwrap(await staged.stand.machine.session(id: staged.sessionId))
        XCTAssertEqual(live.state, .recording, "переход не записан (инвариант 18) — состояние осталось прежним")
        XCTAssertEqual(
            staged.stand.queue.recordingDidStopCallCount, 1, "recordingDidStop зовётся даже при отказе записи"
        )
        await staged.stand.machine.stop()
    }

    // MARK: - К39(б), «порядок» (MEE-428, план MEE-288 §2, дельты АД/АЖ)

    /// К39(б) («порядок»): счётчик один — этого мало, `recordingDidStop()` обязан предшествовать
    /// самой ЗАПИСИ перехода в `failed`, не только случиться где-то до конца теста. Различающий
    /// вектор — реализация, переставившая вызовы (`setStatus` раньше, `recordingDidStop()`
    /// позже): даёт тот же счётчик (1), что и верная, но здесь `happened(before:)` даёт `false` —
    /// при отказе записи перехода (`StorageError`) флаг остался бы поднятым для уже остановленного
    /// захвата.
    ///
    /// Журнал очищается ПОСЛЕ оснастки: `recording(from:)` сама доводит сессию до `.recording`
    /// через более ранние переходы, и `MeetingRepository.setStatus(_:meetingId:)` пишется на
    /// КАЖДОМ из них (`SessionMachine.transition`, единственное место записи статуса). Без
    /// очистки `PortCallLog.firstIndex(of:)` нашёл бы ТУ, раннюю запись — а она предшествует
    /// `recordingDidStop()` естественно, и утверждение о порядке оказалось бы зелёным по
    /// построению, не различающим.
    func test_k39b_recordingDidStopPrecedesTheFailedTransitionWrite() async throws {
        let staged = try await SessionMachineStand.recording(from: moment)
        staged.stand.log.clear()

        await staged.stand.deliver(CaptureEvent.failed(.systemUnavailable(message: "отказ")))
        await staged.stand.machine.tick(now: moment.addingTimeInterval(80))

        XCTAssertEqual(staged.stand.queue.recordingDidStopCallCount, 1, "ровно один вызов на строку 11")
        XCTAssertTrue(
            staged.stand.log.happened(
                "JobQueue.recordingDidStop()", before: "MeetingRepository.setStatus(_:meetingId:)"
            ),
            "К39(б): флаг снят ДО записи перехода — переставленные вызовы дали бы то же число, но не этот порядок"
        )
        await staged.stand.machine.stop()
    }
}
