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

        let stream = harness.port.events()
        let collector = Task { () -> CaptureDiscontinuity? in
            for await event in stream {
                if case .discontinuity(let discontinuity) = event { return discontinuity }
            }
            return nil
        }
        harness.gateway.emit(.tapInvalidated(atHostTime: 9_000))
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

    // СТРОКА: план MEE-315 называет для К11 (половина Б) способ Б — обзор кода; сделано, как и
    // К19 (см. `ModuleTextTests.swift`), способом Г (греп по точному паттерну `reason: .truncated`
    // / `reason: .unknown`, не голой подстрокой — она поймала бы и `AudioCaptureLimits.
    // truncatedTailBudgetMs`, и сравнение `reason != .truncated` в `ScaleError.swift`, ни то ни
    // другое не конструирование). Обзор кода как отдельный ручной шаг вне зоны этой задачи и
    // CI-агностичности способа Г; свой инструмент разбора AST/symbol-graph под этот один критерий —
    // та же цена, что и у К19. Решение о способе Б отдельным инструментом — за РП/QA, как и там.
    //
    /// Инвариант 11, способ Б — обзор кода: `.unknown` не производится реализацией ни разу
    /// (значение только для чтения чужого файла, C-001 §0.3), `.truncated` — только в `recover`.
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

        let stream = harness.port.events()
        let collector = Task { () -> RecordingManifest.DiscontinuityReason? in
            for await event in stream {
                if case .discontinuity(let discontinuity) = event { return discontinuity.reason }
            }
            return nil
        }
        trigger(harness)
        harness.gateway.feed(.samples(.system, frameCount: 480, channelCount: 2, hostTime: 9_200))
        let collected = await collector.value
        return try XCTUnwrap(collected)
    }
}
