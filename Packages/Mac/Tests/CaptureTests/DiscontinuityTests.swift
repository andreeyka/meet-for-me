//  К9, К11 — разрыв двумя путями, причины разрыва ограничены. План MEE-315.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class DiscontinuityTests: CaptureAsyncTestCase {

    // MARK: - К9. Разрыв доезжает двумя путями (событие + манифест) — теми же числами

    func test_k09_discontinuityEventAndManifestAgreeOnTheSameNumbers() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        let collector = Task { () -> CaptureDiscontinuity? in
            for await event in harness.port.events() {
                if case .discontinuity(let discontinuity) = event { return discontinuity }
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        harness.gateway.emit(.tapInvalidated(atHostTime: 9_000))
        try await Task.sleep(nanoseconds: 10_000_000)
        harness.gateway.feed(.samples(.system, frameCount: 480, channelCount: 2, hostTime: 9_120))

        let collected = await collector.value
        let fromEvent = try XCTUnwrap(collected)
        let manifest = try await harness.port.stop()
        let fromManifest = try XCTUnwrap(manifest.discontinuities.first)

        XCTAssertEqual(fromEvent.atMs, fromManifest.atMs)
        XCTAssertEqual(fromEvent.gapMs, fromManifest.gapMs)
        XCTAssertEqual(fromEvent.scaleErrorMs, fromManifest.scaleErrorMs)
        XCTAssertEqual(fromEvent.reason, fromManifest.reason)
        let discontinuityMarkers = manifest.markers.filter { $0.kind == .discontinuity }
        XCTAssertEqual(discontinuityMarkers.count, 1)
        XCTAssertEqual(discontinuityMarkers.first?.atMs, fromManifest.atMs)
    }

    // MARK: - К11. Причины разрыва ограничены — по наблюдённому исходу

    func test_k11_tapInvalidatedProducesSourceGone() async throws {
        let reason = try await discontinuityReason { harness in
            harness.gateway.emit(.tapInvalidated(atHostTime: 9_000))
        }
        XCTAssertEqual(reason, .sourceGone)
    }

    func test_k11_deviceChangeProducesRebuild() async throws {
        let reason = try await discontinuityReason { harness in
            harness.gateway.emit(.microphoneChanged(
                MicrophoneHandle(uid: "airpods", name: "AirPods", channelCount: 1), atHostTime: 9_000
            ))
        }
        XCTAssertEqual(reason, .rebuild)
    }

    /// Инвариант 11, способ Б — обзор кода: `.unknown` не производится реализацией ни разу
    /// (значение только для чтения чужого файла, C-001 §0.3), `.truncated` — только в `recover`.
    /// Точный паттерн `reason: .truncated` — та же осторожность, что и у проверки `.unknown` ниже:
    /// голая подстрока `.truncated` ловит и `AudioCaptureLimits.truncatedTailBudgetMs` (не то же
    /// имя), и сравнение `reason != .truncated` в `ScaleError.swift` (не конструирование).
    func test_k11_unknownNeverConstructedTruncatedOnlyInRecovery() throws {
        let sources = try CaptureSources.sources()
        for file in sources where file.name != "CaptureRecovery.swift" {
            XCTAssertFalse(file.text.contains("reason: .truncated"), "\(file.name): .truncated вне recover")
        }
        for file in sources {
            XCTAssertFalse(file.text.contains("reason: .unknown"), "\(file.name): .unknown сконструирован")
        }
    }

    private func discontinuityReason(
        _ trigger: @escaping (Harness) -> Void
    ) async throws -> RecordingManifest.DiscontinuityReason {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        let collector = Task { () -> RecordingManifest.DiscontinuityReason? in
            for await event in harness.port.events() {
                if case .discontinuity(let discontinuity) = event { return discontinuity.reason }
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        trigger(harness)
        try await Task.sleep(nanoseconds: 10_000_000)
        harness.gateway.feed(.samples(.system, frameCount: 480, channelCount: 2, hostTime: 9_200))
        let collected = await collector.value
        return try XCTUnwrap(collected)
    }
}
