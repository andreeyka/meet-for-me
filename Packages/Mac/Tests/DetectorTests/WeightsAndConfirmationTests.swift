//  Точка приёма Ш5 и срок подтверждения (Ш6, инвариант 24). К3, К45, К47, К73.
//
//  Значения весов строятся чистой функцией `domain-core` `SignalWeights.values(from:)` из байтов,
//  которые задаёт тест, и подаются порту точкой приёма — без пересборки `domain-core`, без
//  подмены ресурса и без обращения к файловой системе. Штатный набор — `SignalWeights.current()`.

import DomainCore
import Foundation
import XCTest
@testable import Detector

final class WeightsAndConfirmationTests: XCTestCase {

    private let chrome = [
        SignalStreamTests.chromeMain,
        SignalStreamTests.chromeHelper(101, output: true, input: true)
    ]

    private func harness(_ bytes: Data? = nil) throws -> Harness {
        guard let bytes else { return try Harness() }
        return try Harness(values: ReferenceTables.received(SignalWeights.values(from: bytes)))
    }

    // MARK: - К3, К47. Вес — из полученного набора

    func test_k03_weightComesFromReceivedValues_notFromCode() async throws {
        let harness = try harness(ReferenceTables.signalWeights(clientRunning: 0.55))
        let stream = harness.detector.signals()
        harness.world.set(chrome, bundleIds: SignalStreamTests.chromeBundles)
        try await harness.detector.startObserving()
        let running = await harness.drain(stream).filter { $0.kind == .clientRunning }
        XCTAssertEqual(running.map(\.weight), [0.55])
    }

    func test_k47_vectorI_shippedWeights() async throws {
        let shipped = try SignalWeights.current()
        let harness = try harness()
        let stream = harness.detector.signals()
        harness.world.set(chrome, bundleIds: SignalStreamTests.chromeBundles)
        try await harness.detector.startObserving()
        let events = await harness.drain(stream)
        let weights = Dictionary(uniqueKeysWithValues: events.map { ($0.kind, $0.weight) })
        XCTAssertEqual(weights[.clientRunning], 0.4)
        XCTAssertEqual(weights[.clientAudioOutput], 0.8)
        XCTAssertEqual(weights[.microphoneInUse], 0.4)
        for signal in events {
            XCTAssertEqual(signal.weight, shipped.weight(for: signal.kind), "значение из загруженной таблицы")
            XCTAssertTrue((0...1).contains(signal.weight))
        }
    }

    func test_k47_vectorII_everyWeightFromReceivedSet_noneFromShipped() async throws {
        let shipped = try SignalWeights.current()
        let harness = try harness(ReferenceTables.signalWeights(clientRunning: 0.55, clientAudioOutput: 0.35,
                                                                microphoneInUse: 0.95))
        let stream = harness.detector.signals()
        harness.world.set(chrome, bundleIds: SignalStreamTests.chromeBundles)
        try await harness.detector.startObserving()
        let events = await harness.drain(stream)
        let weights = Dictionary(uniqueKeysWithValues: events.map { ($0.kind, $0.weight) })
        XCTAssertEqual(weights, [.clientRunning: 0.55, .clientAudioOutput: 0.35, .microphoneInUse: 0.95])
        for signal in events {
            XCTAssertNotEqual(signal.weight, shipped.weight(for: signal.kind), "второго набора у порта нет")
            XCTAssertTrue((0...1).contains(signal.weight))
        }
    }

    // MARK: - К45. Одинаковый снимок: до срока не идёт, по сроку — подтверждение; новый состав — сразу

    func test_k45_vectorI_sameSnapshotBeforeConfirmationAge_doesNotGo() async throws {
        let harness = try harness()
        harness.world.set(chrome, bundleIds: SignalStreamTests.chromeBundles)
        try await harness.detector.startObserving()
        let stream = harness.detector.signals()
        let ttl = try ReferenceTables.shippedValues().signalTtlSeconds
        let age = ConfirmationPolicy.confirmationAge(signalTtlSeconds: ttl)
        harness.world.advance(by: age / 2)
        harness.driver.fire()
        let events = await harness.drain(stream)
        XCTAssertEqual(events, [], "повторное неизменившееся состояние изменением не является")
    }

    func test_k45_vectorIBis_sameSnapshotAfterTtl_goesAsConfirmation() async throws {
        let harness = try harness()
        let stream = harness.detector.signals()
        harness.world.set(chrome, bundleIds: SignalStreamTests.chromeBundles)
        try await harness.detector.startObserving()
        harness.world.advance(by: try ReferenceTables.shippedValues().signalTtlSeconds)
        harness.driver.fire()
        let output = await harness.drain(stream).filter { $0.kind == .clientAudioOutput }
        guard output.count == 2, let first = output.first, let confirmation = output.last else {
            return XCTFail("ожидалась публикация и подтверждение, пришло \(output.count)")
        }
        XCTAssertTrue(first.hasSameState(as: confirmation), "все поля равны, кроме observedAt")
        XCTAssertGreaterThan(confirmation.observedAt, first.observedAt)
    }

    func test_k45_vectorII_changedComposition_goesAtOnce() async throws {
        let harness = try harness()
        harness.world.set(chrome, bundleIds: SignalStreamTests.chromeBundles)
        try await harness.detector.startObserving()
        let stream = harness.detector.signals()
        harness.world.set(chrome + [SignalStreamTests.chromeHelper(102)], bundleIds: SignalStreamTests.chromeBundles)
        harness.world.advance(by: 1)
        harness.driver.fire()
        let output = await harness.drain(stream).filter { $0.kind == .clientAudioOutput }
        XCTAssertEqual(output.map { $0.group?.pids }, [[100, 101, 102]])
    }

    // MARK: - К73. Инвариант 24, половина порта

    func test_k73_holdingState_isConfirmedBeforeTtl_withShippedTable() async throws {
        try await confirmationRun(bytes: nil)
    }

    func test_k73_vectorIV_deadlineComesFromReceivedTtl() async throws {
        try await confirmationRun(bytes: ReferenceTables.signalWeights(signalTtlSeconds: 7))
    }

    /// Держит состояние `3 × signalTtlSeconds` шагами меньше запаса реализации, затем убирает процесс.
    private func confirmationRun(bytes: Data?) async throws {
        let harness = try harness(bytes)
        let ttl = try bytes.map { Double(try SignalWeights.values(from: $0).signalTtlSeconds) }
            ?? ReferenceTables.shippedValues().signalTtlSeconds
        let stepLength = ConfirmationPolicy.confirmationAge(signalTtlSeconds: ttl) / 5
        let stream = harness.detector.signals()
        harness.world.set(chrome, bundleIds: SignalStreamTests.chromeBundles)
        try await harness.detector.startObserving()
        XCTAssertLessThan(try XCTUnwrap(harness.driver.interval), ttl, "шаг наблюдения короче срока")
        for _ in 0..<Int((3 * ttl / stepLength).rounded(.up)) {
            harness.world.advance(by: stepLength)
            harness.driver.fire()
        }
        let lastHeld = harness.world.now()
        harness.world.set([], bundleIds: [:])
        for _ in 0..<Int((2 * ttl / stepLength).rounded(.up)) {
            harness.world.advance(by: stepLength)
            harness.driver.fire()
        }
        let pair = await harness.drain(stream).filter {
            $0.kind == .clientAudioOutput && $0.group?.appKey == "com.google.Chrome"
        }
        XCTAssertGreaterThanOrEqual(pair.count, 3, "ttl \(ttl)")
        for (previous, next) in zip(pair, pair.dropFirst()) {
            XCTAssertLessThan(next.observedAt.timeIntervalSince(previous.observedAt), ttl, "ttl \(ttl)")
            XCTAssertGreaterThan(next.observedAt, previous.observedAt)
            XCTAssertTrue(next.hasSameState(as: previous), "подтверждение — обычная публикация того же значения")
        }
        XCTAssertTrue(pair.allSatisfy { $0.observedAt <= lastHeld }, "после ухода процесса событий пары нет")
    }
}
