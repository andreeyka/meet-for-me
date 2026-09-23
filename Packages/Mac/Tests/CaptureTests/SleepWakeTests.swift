//  Сон/пробуждение (§«Поведение», возврат части 1 — п. 6): источник — `.willSleep`/`.didWake`
//  C-008 (`PowerPort.events()`), после `.didWake` порт берёт НОВЫЙ токен удержания.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class SleepWakeTests: CaptureAsyncTestCase {

    func test_sleepMarksAndDiscontinuityWakeTakesNewToken() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(harness.power.beginActivityCallCount, 1)

        harness.power.emit(.willSleep)
        try await Task.sleep(nanoseconds: 10_000_000)
        harness.power.emit(.didWake)
        try await Task.sleep(nanoseconds: 10_000_000)

        // «После .didWake порт берёт новый токен удержания» — дословно контракт: старый
        // закрыт (недействителен вместе со сном), взят новый — два вызова beginActivity на сеанс.
        XCTAssertEqual(harness.power.beginActivityCallCount, 2, "новый токен взят после пробуждения")
        XCTAssertEqual(harness.power.liveActivities.count, 1, "старый закрыт, живой ровно один")

        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 2_000))
        let manifest = try await harness.port.stop()

        XCTAssertTrue(manifest.markers.contains { $0.kind == .sleep })
        XCTAssertTrue(manifest.markers.contains { $0.kind == .wake })
        XCTAssertTrue(manifest.discontinuities.contains { $0.reason == .sleep })
        XCTAssertEqual(harness.power.liveActivities.count, 0, "stop снимает и новый токен")
    }

    /// Возврат MEE-317 (второй круг): раньше маркер `.discontinuity` от сна ставился без парного
    /// элемента в `discontinuities` — инвариант 15 C-002 нарушался, и `stop()` до пробуждения
    /// бросал `systemUnavailable` (сборка манифеста кидала ошибку валидации). Проверяет именно
    /// это: `stop()` не бросает, и в манифесте есть согласованная пара маркер+разрыв.
    func test_sleepThenStopBeforeWakeDoesNotThrow() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        try await Task.sleep(nanoseconds: 10_000_000)

        harness.power.emit(.willSleep)
        try await Task.sleep(nanoseconds: 10_000_000)

        let manifest = try await harness.port.stop()
        XCTAssertTrue(manifest.markers.contains { $0.kind == .sleep })
        let discontinuityMarkers = manifest.markers.filter { $0.kind == .discontinuity }
        XCTAssertEqual(discontinuityMarkers.count, 1, "один маркер разрыва от сна")
        XCTAssertEqual(manifest.discontinuities.filter { $0.reason == .sleep }.count, 1,
                       "маркер и запись в паре — иначе инвариант 15 не прошёл бы саму сборку манифеста")
    }

    /// Тот же дефект, наблюдаемый со стороны диска, а не через `stop()`: манифест обязан
    /// оставаться читаемым (проходить валидацию домена) сразу после `.willSleep`, до всякого
    /// пробуждения — контракт требует записи на диск немедленно, не только у `stop()`.
    func test_sleepWritesValidManifestToDiskImmediately() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        try await Task.sleep(nanoseconds: 10_000_000)

        harness.power.emit(.willSleep)
        try await Task.sleep(nanoseconds: 10_000_000)

        // ManifestWriter.read декодирует и валидирует домен целиком (DomainJSON.decode) — раньше
        // здесь либо не было файла вовсе (writeManifest молча проглатывал ошибку валидации через
        // `try?`), либо файл не содержал следа сна.
        let onDisk = try ManifestWriter.read(from: directory)
        XCTAssertTrue(onDisk.markers.contains { $0.kind == .sleep })
        XCTAssertTrue(onDisk.markers.contains { $0.kind == .discontinuity })
        XCTAssertTrue(onDisk.discontinuities.contains { $0.reason == .sleep })

        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 2_000))
        harness.power.emit(.didWake)
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await harness.port.stop()
    }

    /// Сон поверх ЕЩЁ ОТКРЫТОЙ пересборки (другая причина уже заняла `pendingRebuild`):
    /// `beginRebuild(reason: .sleep)` не заводит новый `pendingRebuild` (охрана на его первой
    /// строке) — маркер `.discontinuity` для сна в этом случае НЕ ставится вовсе, иначе он
    /// остался бы без пары навсегда (инвариант 15). `.sleep`-маркер сам по себе безусловен и
    /// ставится в любом случае — пары не требует.
    func test_sleepDuringPendingRebuildDoesNotOrphanDiscontinuityMarker() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        try await Task.sleep(nanoseconds: 10_000_000)

        // Пересборка началась (смена микрофона), но не разрешена — pendingRebuild открыт до
        // первого буфера новой сборки.
        harness.gateway.emit(.microphoneChanged(
            MicrophoneHandle(uid: "airpods", name: "AirPods", channelCount: 1), atHostTime: 2_000
        ))
        try await Task.sleep(nanoseconds: 10_000_000)

        harness.power.emit(.willSleep)
        try await Task.sleep(nanoseconds: 10_000_000)

        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 2_100))
        try await Task.sleep(nanoseconds: 10_000_000)

        let manifest = try await harness.port.stop()
        XCTAssertTrue(manifest.markers.contains { $0.kind == .sleep }, "маркер .sleep безусловен")
        let discontinuityMarkers = manifest.markers.filter { $0.kind == .discontinuity }
        XCTAssertEqual(discontinuityMarkers.count, 1, "ровно один разрыв — от пересборки, не от потерявшегося сна")
        XCTAssertEqual(manifest.discontinuities.count, 1)
        XCTAssertEqual(manifest.discontinuities.first?.reason, .rebuild,
                       "сон поверх уже идущей пересборки не подменяет её причину своей")
    }
}
