//  К12, К13, К14 — состав захвата, containsUnrequested, captureGroupKey. План MEE-315.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class CapturedProcessTests: CaptureAsyncTestCase {

    // MARK: - К12. Состав захвата перечитывается и публикуется

    func test_k12_periodicPollPublishesAndUnionAccumulatesInManifest() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let group = ProcessGroup(appKey: "us.zoom.xos", pids: [111], observedAt: Date())
        try await harness.start(directory: directory, group: group)
        let tap = try XCTUnwrap(harness.gateway.lastCreatedTap, "start() уже разрешил tap")

        let first = CaptureProcessDescriptor(pid: 111, bundleId: "us.zoom.xos", executableName: "zoom.us")
        let second = CaptureProcessDescriptor(pid: 222, bundleId: "us.zoom.xos.helper", executableName: "helper")

        let collector = Task { () -> CapturedProcessSnapshot? in
            for await event in harness.port.events() {
                if case .capturedProcessesChanged(let snapshot) = event { return snapshot }
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        // «Не реже раза в capturedProcessesPollSeconds, даже без единого события шва» — таймер
        // самого порта, не событие шва: сеанс не порождал ни одного processesChanged.
        harness.gateway.setCapturedProcesses([first], for: tap)
        harness.port.pollCapturedProcesses()
        let collected = await collector.value
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.requestedAppKey, "us.zoom.xos")

        // Второй снимок — другой процесс; манифест хранит ОБЪЕДИНЕНИЕ, не последний снимок.
        harness.gateway.setCapturedProcesses([second], for: tap)
        harness.port.pollCapturedProcesses()
        try await Task.sleep(nanoseconds: 10_000_000)

        let manifest = try await harness.port.stop()
        let pids = Set(manifest.capturedProcesses.map(\.pid))
        XCTAssertEqual(pids, [111, 222], "объединение всех снимков, не последний снимок")
    }

    // MARK: - К12 (продолжение). Публикация при старте и при пересборке — не только по опросу

    /// Возврат MEE-317 (24.09), инвариант 12(а): «при старте сеанса», буквально — не только по
    /// таймеру опроса (тест выше) и не только по событию шва `.processesChanged`. `capturedProcesses`
    /// заводится ДО того, как `start()` вернёт управление, — тест ловит это как первое событие,
    /// пришедшее подписчику, подключённому ДО вызова `start`.
    func test_k12_capturedProcessesChangedPublishedAtSessionStart() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let knownTap = TapHandle()
        let group = ProcessGroup(appKey: "us.zoom.xos", pids: [111], observedAt: Date())
        let request = Harness.request(directory: directory, group: group)
        harness.gateway.setCapturedProcesses(
            [CaptureProcessDescriptor(pid: 111, bundleId: "us.zoom.xos", executableName: "zoom.us")], for: knownTap
        )

        let collector = Task { () -> CapturedProcessSnapshot? in
            for await event in harness.port.events() {
                if case .capturedProcessesChanged(let snapshot) = event { return snapshot }
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        async let started = harness.port.start(request)
        try await Task.sleep(nanoseconds: 20_000_000)
        harness.gateway.resolveTap(with: .created(knownTap))
        try await Task.sleep(nanoseconds: 5_000_000)
        harness.gateway.resolveMicrophone(with: .opened(
            MicrophoneHandle(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", channelCount: 1)
        ))
        _ = try await started

        let received = await collector.value
        let snapshot = try XCTUnwrap(received)
        XCTAssertEqual(snapshot.processes.map(\.pid), [111], "снимок, заданный ДО start(), пришёл при самом старте")
    }

    /// Инвариант 12(б): «при каждой пересборке aggregate device» — та же гарантия, что при
    /// старте, но по другому триггеру (инвалидация tap — тот же tap переживает пересборку,
    /// инвариант 4). Подписчик подключается ПОСЛЕ `start()`, чтобы не поймать стартовый снимок.
    func test_k12_capturedProcessesChangedPublishedOnEveryRebuild() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let group = ProcessGroup(appKey: "us.zoom.xos", pids: [111], observedAt: Date())
        try await harness.start(directory: directory, group: group)
        let tap = try XCTUnwrap(harness.gateway.lastCreatedTap)

        let collector = Task { () -> CapturedProcessSnapshot? in
            for await event in harness.port.events() {
                if case .capturedProcessesChanged(let snapshot) = event { return snapshot }
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        harness.gateway.setCapturedProcesses(
            [CaptureProcessDescriptor(pid: 111, bundleId: "us.zoom.xos", executableName: "zoom.us"),
             CaptureProcessDescriptor(pid: 333, bundleId: "us.zoom.xos.helper", executableName: "helper")],
            for: tap
        )
        harness.gateway.emit(.tapInvalidated(atHostTime: 9_000))

        let received = await collector.value
        let snapshot = try XCTUnwrap(received)
        XCTAssertEqual(Set(snapshot.processes.map(\.pid)), [111, 333], "снимок читается заново на каждой пересборке")
    }

    // MARK: - К13. containsUnrequested

    func test_k13_containsUnrequestedTrueOnlyWhenAMismatchedProcessIsPresent() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let group = ProcessGroup(appKey: "us.zoom.xos", pids: [111], observedAt: Date())
        try await harness.start(directory: directory, group: group)

        let matched = CaptureProcessDescriptor(pid: 111, bundleId: "us.zoom.xos", executableName: "zoom.us")
        // Дочерний бандл того же приложения (C-009 §4.1, шаг 2: `k == B || k.hasPrefix(B + ".")`) —
        // не считается посторонним, хотя строкой не совпадает с requestedAppKey дословно.
        let helper = CaptureProcessDescriptor(pid: 112, bundleId: "us.zoom.xos.helper", executableName: "helper")
        let foreign = CaptureProcessDescriptor(pid: 999, bundleId: "com.apple.WebKit.GPU", executableName: "WebKit")

        let collector = Task { () -> [CapturedProcessSnapshot] in
            var collected: [CapturedProcessSnapshot] = []
            for await event in harness.port.events() {
                if case .capturedProcessesChanged(let snapshot) = event {
                    collected.append(snapshot)
                    if collected.count >= 3 { break }
                }
            }
            return collected
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        harness.gateway.emit(.processesChanged([matched, foreign], atHostTime: 1_000))
        try await Task.sleep(nanoseconds: 10_000_000)
        harness.gateway.emit(.processesChanged([matched, helper], atHostTime: 2_000))
        try await Task.sleep(nanoseconds: 10_000_000)
        harness.gateway.emit(.processesChanged([matched], atHostTime: 3_000))

        let snapshots = await collector.value
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertTrue(snapshots[0].containsUnrequested, "посторонний bundle id в снимке")
        XCTAssertFalse(snapshots[1].containsUnrequested, "дочерний бандл — тот же appKey по правилу шага 2")
        XCTAssertFalse(snapshots[2].containsUnrequested, "только запрошенный процесс")
    }

    func test_k13_requestedAppKeyNilMeansAlwaysFalse() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory, group: nil, input: .systemDefault)

        let collector = Task { () -> CapturedProcessSnapshot? in
            for await event in harness.port.events() {
                if case .capturedProcessesChanged(let snapshot) = event { return snapshot }
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        harness.gateway.emit(.processesChanged(
            [CaptureProcessDescriptor(pid: 1, bundleId: "anything", executableName: nil)], atHostTime: 1_000
        ))
        let collected = await collector.value
        let snapshot = try XCTUnwrap(collected)
        XCTAssertFalse(snapshot.containsUnrequested)
    }

    // MARK: - К14. captureGroupKey

    func test_k14_captureGroupKeyEqualsAppKeyVerbatim() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let group = ProcessGroup(appKey: "com.example.Zoom", pids: [1], observedAt: Date())
        let started = try await harness.start(directory: directory, group: group)
        XCTAssertEqual(started.captureGroupKey, "com.example.Zoom")
        let manifest = try await harness.port.stop()
        XCTAssertEqual(manifest.captureGroupKey, "com.example.Zoom")
    }

    func test_k14_captureGroupKeyNilWhenGroupNil() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let started = try await harness.start(directory: directory, group: nil, input: .systemDefault)
        XCTAssertNil(started.captureGroupKey)
    }
}
