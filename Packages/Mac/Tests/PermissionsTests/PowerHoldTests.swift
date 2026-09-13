//  Критерии перечня MEE-74 на удержания `PowerPort` (C-008): 55–61, 64.
//
//  Удержание сна наблюдается глазами системы — `IOPMCopyAssertionsByProcess` у своего pid;
//  удержание App Nap публичным вызовом не читается (§11.3 части 2/2), поэтому его половина
//  проверяется через шов — списком системных удержаний, взятых модулем.

import DomainCore
import Foundation
import XCTest
@testable import Permissions

final class PowerHoldTests: XCTestCase {

    // MARK: - 55. Токен возвращается, даже когда удержать систему не удалось

    func test_c55_tokenReturnedWhenSystemRefuses() async {
        let harness = PowerHarness(holds: FailingHoldService())
        let token = await harness.sut.beginActivity(reason: .recording, label: "x")
        XCTAssertEqual(token.reason, .recording)
        XCTAssertEqual(token.label, "x")
        XCTAssertEqual(harness.sut.holds.activeSystemHolds, [])
        XCTAssertEqual(harness.sut.holds.liveCount(.preventIdleSystemSleep), 1)
        XCTAssertFalse(PowerAssertions.holdsPreventIdleSleep())
        token.end()
        XCTAssertEqual(harness.sut.holds.liveCount(.preventIdleSystemSleep), 0)
    }

    // MARK: - 56. end() идемпотентен

    func test_c56_endIsIdempotent() async {
        let harness = PowerHarness()
        let token = await harness.sut.beginActivity(reason: .recording, label: "a")
        XCTAssertTrue(PowerAssertions.holdsPreventIdleSleep())
        token.end()
        XCTAssertFalse(PowerAssertions.holdsPreventIdleSleep())
        token.end()
        token.end()
        XCTAssertFalse(PowerAssertions.holdsPreventIdleSleep())
        XCTAssertEqual(harness.sut.holds.activeSystemHolds, [])
    }

    // MARK: - 57. Освобождение токена без end() снимает удержание

    func test_c57_releasingTokenWithoutEnd_removesHold() async {
        let harness = PowerHarness()
        let heldInsideScope = await takeAndDrop(harness.sut)
        XCTAssertTrue(heldInsideScope)
        XCTAssertFalse(PowerAssertions.holdsPreventIdleSleep())
        XCTAssertEqual(harness.sut.holds.activeSystemHolds, [])
    }

    private func takeAndDrop(_ sut: SystemPower) async -> Bool {
        let token = await sut.beginActivity(reason: .recording, label: "c57")
        return withExtendedLifetime(token) { PowerAssertions.holdsPreventIdleSleep() }
    }

    // MARK: - 58, 59. Ограничение снимается по последнему токену причины

    func test_c58_recordingHold_releasedByLastToken() async {
        let harness = PowerHarness()
        let tokens = await [harness.sut.beginActivity(reason: .recording, label: "1"),
                            harness.sut.beginActivity(reason: .recording, label: "2"),
                            harness.sut.beginActivity(reason: .recording, label: "3")]
        XCTAssertTrue(PowerAssertions.holdsPreventIdleSleep())
        tokens[0].end()
        XCTAssertTrue(PowerAssertions.holdsPreventIdleSleep(), "после первого end()")
        tokens[1].end()
        XCTAssertTrue(PowerAssertions.holdsPreventIdleSleep(), "после второго end()")
        tokens[2].end()
        XCTAssertFalse(PowerAssertions.holdsPreventIdleSleep(), "после третьего end()")
    }

    func test_c59_processingHold_releasedByLastToken() async {
        let harness = PowerHarness()
        let tokens = await [harness.sut.beginActivity(reason: .processing, label: "1"),
                            harness.sut.beginActivity(reason: .processing, label: "2"),
                            harness.sut.beginActivity(reason: .processing, label: "3")]
        XCTAssertTrue(harness.sut.holds.activeSystemHolds.contains(.preventAppNap))
        tokens[0].end()
        XCTAssertTrue(harness.sut.holds.activeSystemHolds.contains(.preventAppNap), "после первого end()")
        tokens[1].end()
        XCTAssertTrue(harness.sut.holds.activeSystemHolds.contains(.preventAppNap), "после второго end()")
        tokens[2].end()
        XCTAssertFalse(harness.sut.holds.activeSystemHolds.contains(.preventAppNap), "после третьего end()")
    }

    // MARK: - 60. .recording — сон и App Nap; .processing — только App Nap

    func test_c60_recordingHoldsSleepAndAppNap_processingOnlyAppNap() async {
        let harness = PowerHarness()
        let recording = await harness.sut.beginActivity(reason: .recording, label: "rec")
        XCTAssertTrue(PowerAssertions.holdsPreventIdleSleep())
        XCTAssertEqual(harness.sut.holds.activeSystemHolds, [.preventIdleSystemSleep, .preventAppNap])
        recording.end()
        XCTAssertEqual(harness.sut.holds.activeSystemHolds, [])
        let processing = await harness.sut.beginActivity(reason: .processing, label: "proc")
        XCTAssertFalse(PowerAssertions.holdsPreventIdleSleep(), "обработка сна не запрещает")
        XCTAssertEqual(harness.sut.holds.activeSystemHolds, [.preventAppNap])
        processing.end()
        XCTAssertEqual(harness.sut.holds.activeSystemHolds, [])
    }

    // MARK: - 61. Смешанное состояние

    func test_c61_mixedRecordingAndProcessing() async {
        let harness = PowerHarness()
        let recording = await harness.sut.beginActivity(reason: .recording, label: "rec")
        let processing = await harness.sut.beginActivity(reason: .processing, label: "proc")
        XCTAssertTrue(PowerAssertions.holdsPreventIdleSleep())
        recording.end()
        XCTAssertFalse(PowerAssertions.holdsPreventIdleSleep(), "удержание сна снято")
        XCTAssertTrue(harness.sut.holds.activeSystemHolds.contains(.preventAppNap), "запрет App Nap сохраняется")
        processing.end()
        XCTAssertEqual(harness.sut.holds.activeSystemHolds, [])
    }

    // MARK: - 64. После .didWake порт сам нового удержания не берёт

    func test_c64_noNewHoldAfterWake() async {
        let harness = PowerHarness()
        let token = await harness.sut.beginActivity(reason: .recording, label: "rec")
        let stream = harness.sut.events()
        harness.signals.fire(.willSleep)
        harness.signals.fire(.didWake)
        let events = await Streams.take(stream, 2)
        XCTAssertEqual(events, [.willSleep, .didWake])
        XCTAssertEqual(harness.sut.holds.liveCount(.preventIdleSystemSleep), 1)
        XCTAssertEqual(harness.sut.holds.liveCount(.preventAppNap), 1)
        token.end()
        XCTAssertEqual(harness.sut.holds.liveCount(.preventIdleSystemSleep), 0)
    }

    // MARK: - 62, чтением сигнатуры: у токена причина неизменяема

    func test_c62_tokenReasonIsImmutable() async {
        let token = await PowerHarness().sut.beginActivity(reason: .recording, label: "x")
        let mirror = Mirror(reflecting: token)
        XCTAssertTrue(mirror.children.contains { $0.label == "reason" })
        XCTAssertEqual(token.reason, .recording)
        token.end()
    }
}
