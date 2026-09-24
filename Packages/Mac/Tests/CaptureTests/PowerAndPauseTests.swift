//  К23, К24 — удержание системы, пауза не разрыв. План MEE-315.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class PowerAndPauseTests: CaptureAsyncTestCase {

    // MARK: - К23. Удержание системы

    func test_k23_oneTokenPerSessionReleasedOnStop() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        XCTAssertEqual(harness.power.beginActivityCallCount, 1)
        XCTAssertEqual(harness.power.liveActivities.count, 1)

        _ = try await harness.port.stop()
        XCTAssertEqual(harness.power.liveActivities.count, 0, "после stop живых токенов не остаётся")
    }

    /// Отказ ДО того, как право могло дать токен: закрыт отдельно от отказа ПОСЛЕ (следующий тест) —
    /// раздельные проверки одного и того же поля с разных сторон гонки, план MEE-315.
    func test_k23_failureBeforeTokenCouldBeTakenLeavesNoLiveToken() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, input: .none)

        async let started = harness.port.start(request)
        try await Task.sleep(nanoseconds: 20_000_000)
        harness.gateway.resolveTap(with: .permissionDenied)
        do {
            _ = try await started
            XCTFail("ожидался systemAudioDenied")
        } catch CaptureError.systemAudioDenied {}

        XCTAssertEqual(harness.power.beginActivityCallCount, 0,
                       "токен вообще не берётся, пока start не дошёл до сборки")
        XCTAssertEqual(harness.power.liveActivities.count, 0)
    }

    /// Возврат части 1, п. 1: прежний тест бил по отказу ДО взятия токена (право отказало раньше
    /// сборки) — критерий требует и отказ ПОСЛЕ того, как токен мог быть взят. `aggregateBuildError`
    /// бьёт по сборке aggregate, которая в реализации идёт уже после `power.beginActivity(...)`.
    func test_k23_failureAfterTokenTakenReleasesIt() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        harness.gateway.aggregateBuildError = CaptureError.systemUnavailable(message: "diagnostic")

        do {
            _ = try await harness.start(directory: directory)
            XCTFail("ожидался systemUnavailable")
        } catch CaptureError.systemUnavailable {}

        XCTAssertEqual(harness.power.beginActivityCallCount, 1, "токен был взят — отказ случился уже после")
        XCTAssertEqual(harness.power.liveActivities.count, 0, "и снят при откате")
    }

    // MARK: - К24. Пауза не разрыв

    /// Возврат части 1, п. 2: до паузы не было подано ни одного буфера, и `atMs` паузы и
    /// возобновления совпадали 0 == 0 по построению — теперь шкала до паузы продвинута реальными
    /// буферами, и совпадение проверяет именно то, что заявлено: пауза её не сдвигает.
    func test_k24_pauseResumeDoesNotAdvanceScaleOrCreateDiscontinuity() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        harness.gateway.feed(.samples(.mic, frameCount: 4_800, channelCount: 1, hostTime: 1_000))
        try await Task.sleep(nanoseconds: 20_000_000)

        try await harness.port.pause()
        try await harness.port.resume()

        let manifest = try await harness.port.stop()
        let pauseMarkers = manifest.markers.filter { $0.kind == .pause }
        let resumeMarkers = manifest.markers.filter { $0.kind == .resume }
        XCTAssertEqual(pauseMarkers.count, 1)
        XCTAssertEqual(resumeMarkers.count, 1)
        XCTAssertGreaterThan(pauseMarkers.first?.atMs ?? 0, 0, "шкала уже продвинута буферами до паузы")
        XCTAssertEqual(pauseMarkers.first?.atMs, resumeMarkers.first?.atMs, "шкала не продвинулась во время паузы")
        XCTAssertTrue(manifest.discontinuities.isEmpty, "пауза не порождает разрыва")
    }

    /// Возврат части 1, п. 2: у отказа «буфер во время паузы не записан» не было положительного
    /// контроля — тот же буфер тем же тестом ДО и ПОСЛЕ паузы: до и после пишутся кадры, во время
    /// паузы — нет. Без контроля 0 кадров неотличимо от сломанной записи вообще.
    func test_k24_bufferDuringPauseIsNotWritten() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 500))
        try await Task.sleep(nanoseconds: 20_000_000)

        try await harness.port.pause()
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        try await Task.sleep(nanoseconds: 20_000_000)
        try await harness.port.resume()

        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_500))
        try await Task.sleep(nanoseconds: 20_000_000)

        let manifest = try await harness.port.stop()
        let micFrames = TrackFile.framesOnDisk(
            at: directory.appendingPathComponent("audio-mic.caf"),
            channelCount: manifest.tracks.first { $0.channel == .mic }?.channelCount ?? 1
        )
        // Положительный контроль: до и после паузы поданы те же 480 кадров каждый раз — оба
        // пишутся (960 в сумме), середина (тоже 480, во время паузы) — нет.
        XCTAssertEqual(micFrames, 960, "буфер до и после паузы записан, поданный во время паузы — нет")
    }
}
