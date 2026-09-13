//  Критерии блока E перечня MEE-75: поток сигналов, наблюдение, группы.
//  К41—К44, К46, К48—К53, К61, К62.
//
//  Снимки подаёт тест точкой подачи Ш4, момент — часами Ш6; всё остальное исполняет настоящий
//  `SignalEngine`. Окно каждого критерия короче срока подтверждения (К41—К44 в редакции АВ.6
//  плана): часы теста между шагами не доходят до половины `signalTtlSeconds`.

import DomainCore
import Foundation
import XCTest
@testable import Detector

final class SignalStreamTests: XCTestCase {

    static let chromeMain = Record.make(100, bundle: "com.google.Chrome", responsible: 100)
    static let chromeBundles: [Int32: String] = [100: "com.google.Chrome"]

    static func chromeHelper(_ pid: Int32, output: Bool = false, input: Bool = false) -> RawProcessRecord {
        Record.make(pid, bundle: "com.google.Chrome.helper", responsible: 100, output: output, input: input)
    }

    // MARK: - К41, К42. Инвариант 13

    func test_k41_secondStart_createsNoSecondStream() async throws {
        let harness = try Harness()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101)], bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        try await harness.detector.startObserving()
        let stream = harness.detector.signals()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true)], bundleIds: Self.chromeBundles)
        harness.world.advance(by: 1)
        harness.driver.fire()
        let events = await harness.drain(stream)
        XCTAssertEqual(events.map(\.kind), [.clientAudioOutput], "ровно одно событие")
        XCTAssertEqual(harness.driver.starts, 1, "второй драйвер наблюдения не заведён")
    }

    func test_k42_startStopStart_eventArrives() async throws {
        let harness = try Harness()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101)], bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        await harness.detector.stopObserving()
        try await harness.detector.startObserving()
        let stream = harness.detector.signals()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true)], bundleIds: Self.chromeBundles)
        harness.world.advance(by: 1)
        harness.driver.fire()
        let events = await harness.drain(stream)
        XCTAssertEqual(events.map(\.kind), [.clientAudioOutput])
    }

    // MARK: - К43, К44. Поток после подписки; наблюдение без подписчиков

    func test_k43_subscriberGetsOnlyEventsAfterSubscription() async throws {
        let harness = try Harness()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101)], bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        let early = harness.detector.signals()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true)], bundleIds: Self.chromeBundles)
        harness.world.advance(by: 1)
        harness.driver.fire()
        let stream = harness.detector.signals()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true, input: true)],
                          bundleIds: Self.chromeBundles)
        harness.world.advance(by: 1)
        harness.driver.fire()
        let first = await harness.drain(early).filter { $0.kind == .clientAudioOutput }
        let events = await harness.drain(stream)
        XCTAssertEqual(events.map(\.kind), [.microphoneInUse], "получено №2")
        guard first.count == 1, let transitionOne = first.first else {
            return XCTFail("переход №1 опубликован \(first.count) раз вместо одного")
        }
        XCTAssertFalse(events.contains(transitionOne), "№1 — тождеством, включая observedAt — не получено")
    }

    func test_k44_observationSurvivesAbsenceOfSubscribers() async throws {
        let harness = try Harness()
        harness.world.set([], bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        for pids in [[Int32(101)], [101, 102], [101]] {
            harness.world.set([Self.chromeMain] + pids.map { Self.chromeHelper($0, output: true) },
                              bundleIds: Self.chromeBundles)
            harness.world.advance(by: 1)
            harness.driver.fire()
        }
        let stream = harness.detector.signals()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true), Self.chromeHelper(103)],
                          bundleIds: Self.chromeBundles)
        harness.world.advance(by: 1)
        harness.driver.fire()
        let events = await harness.drain(stream)
        XCTAssertTrue(events.contains { $0.kind == .clientAudioOutput && $0.group?.pids == [100, 101, 103] })
        XCTAssertEqual(harness.driver.stops, 0, "stopObserving не вызывался")
        XCTAssertTrue(harness.driver.isRunning, "наблюдение не остановилось само")
    }

    // MARK: - К46. Смерть процесса — не ошибка

    func test_k46_deathOfProcess_signalGoesOnSameSnapshot_streamContinues() async throws {
        let harness = try Harness()
        let full = [Self.chromeMain, Self.chromeHelper(101, output: true), Self.chromeHelper(102)]
        harness.world.set(full, bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        let stream = harness.detector.signals()
        harness.world.set(Array(full.prefix(2)), bundleIds: Self.chromeBundles)
        harness.world.advance(by: 1)
        harness.driver.fire()
        harness.world.set([], bundleIds: [:])
        harness.world.advance(by: 1)
        harness.driver.fire()
        let gone = try await harness.detector.audioProcesses()
        XCTAssertEqual(gone, [])
        harness.world.set(full, bundleIds: Self.chromeBundles)
        harness.world.advance(by: 1)
        harness.driver.fire()
        let events = await harness.drain(stream)
        let shorter = events.filter { $0.kind == .clientAudioOutput && $0.group?.pids == [100, 101] }
        XCTAssertEqual(shorter.count, 1, "сигнал на том же снимке, где pid исчез")
        XCTAssertTrue(events.contains { $0.group?.pids == [100, 101, 102] }, "поток не завершился")
    }

    // MARK: - К48, К49, К50, К61. Форма сигналов на корпусе

    func test_k48_k61_corpus_everySignalHasPid_noCalendarWindow() async throws {
        let harness = try Harness()
        let stream = harness.detector.signals()
        try await harness.detector.startObserving()
        let corpus: [[RawProcessRecord]] = [
            [Self.chromeMain, Self.chromeHelper(101, output: true)],
            [Self.chromeMain, Self.chromeHelper(101, output: true, input: true), Self.chromeHelper(102)],
            [Record.make(700, bundle: nil, input: true), Record.make(812, bundle: "us.zoom.xos", output: true)],
            []
        ]
        for snapshot in corpus {
            harness.world.set(snapshot, bundleIds: Self.chromeBundles)
            harness.world.advance(by: 1)
            harness.driver.fire()
        }
        let events = await harness.drain(stream)
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.pid != nil })
        XCTAssertEqual(events.filter { $0.kind == .calendarWindow }.count, 0)
    }

    func test_k49_clientSignals_carryMatchedGroup() async throws {
        let harness = try Harness()
        let stream = harness.detector.signals()
        let unknownPlayer = Record.make(300, bundle: "com.example.player", responsible: 300, output: true)
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true), unknownPlayer],
                          bundleIds: Self.chromeBundles.merging([300: "com.example.player"]) { $1 })
        try await harness.detector.startObserving()
        let events = await harness.drain(stream).filter { [.clientRunning, .clientAudioOutput].contains($0.kind) }
        let tables = try ReferenceTables.tables()
        XCTAssertEqual(events.map(\.kind), [.clientRunning, .clientAudioOutput],
                       "приложение вне таблиц сигнала не даёт")
        for signal in events {
            let group = try XCTUnwrap(signal.group)
            XCTAssertEqual(group.appKey, "com.google.Chrome")
            XCTAssertFalse(group.appKey.isEmpty)
            let rows = tables.browsers + tables.clients.flatMap(\.bundleIds)
            XCTAssertTrue(rows.contains { bundleKeyMatches(appKey: group.appKey, entry: $0) })
        }
    }

    func test_k50_microphoneWithoutApplicationKey_hasNoGroup() async throws {
        let harness = try Harness()
        let stream = harness.detector.signals()
        harness.world.set([Record.make(700, bundle: nil, input: true)])
        try await harness.detector.startObserving()
        let events = await harness.drain(stream)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .microphoneInUse)
        XCTAssertNil(events.first?.group)
        XCTAssertEqual(events.first?.pid, 700)
    }

    // MARK: - К51, К52, К53. Группа, провайдер, bundle id источника

    func test_k51_groupPids_sortedUnique_observedAtIsSnapshotMoment() async throws {
        let harness = try Harness()
        let stream = harness.detector.signals()
        harness.world.advance(by: 42)
        let moment = harness.world.now()
        harness.world.set([Record.make(900, bundle: "com.google.Chrome", responsible: 900),
                           Record.make(120, bundle: "com.google.Chrome.helper", responsible: 900, output: true),
                           Record.make(900, bundle: "com.google.Chrome", responsible: 900)],
                          bundleIds: [900: "com.google.Chrome"])
        try await harness.detector.startObserving()
        let events = await harness.drain(stream)
        XCTAssertFalse(events.isEmpty)
        for signal in events {
            let group = try XCTUnwrap(signal.group)
            XCTAssertEqual(group.pids, [120, 900])
            XCTAssertTrue(group.pids.contains(try XCTUnwrap(signal.pid)))
            XCTAssertEqual(group.observedAt, moment)
            XCTAssertEqual(signal.observedAt, moment)
        }
    }

    func test_k52_browserGroupHasNoProvider_nativeClientHasOne() async throws {
        let harness = try Harness()
        let stream = harness.detector.signals()
        harness.world.set([Self.chromeMain, Record.make(812, bundle: "us.zoom.xos", output: true)],
                          bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        let events = await harness.drain(stream)
        let chrome = events.filter { $0.group?.appKey == "com.google.Chrome" }
        let zoom = events.filter { $0.group?.appKey == "us.zoom.xos" }
        XCTAssertFalse(chrome.isEmpty)
        XCTAssertFalse(zoom.isEmpty)
        XCTAssertTrue(chrome.allSatisfy { $0.provider == nil })
        XCTAssertTrue(zoom.allSatisfy { $0.provider == "zoom" })
    }

    func test_k53_sourceBundleIdAndApplicationKey_areNotSwapped() async throws {
        let harness = try Harness()
        let stream = harness.detector.signals()
        harness.world.set([Self.chromeHelper(101, output: true)], bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        let events = await harness.drain(stream)
        XCTAssertFalse(events.isEmpty)
        for signal in events {
            XCTAssertEqual(signal.bundleId, "com.google.Chrome.helper")
            XCTAssertEqual(signal.group?.appKey, "com.google.Chrome")
        }
    }

    // MARK: - К62. Новый состав — новый observedAt, равный моменту снимка

    func test_k62_changedComposition_observedAtIsSnapshotMoment_andGrows() async throws {
        let harness = try Harness()
        let stream = harness.detector.signals()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true)], bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        harness.world.advance(by: 7)
        let second = harness.world.now()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true), Self.chromeHelper(102)],
                          bundleIds: Self.chromeBundles)
        harness.driver.fire()
        let events = await harness.drain(stream).filter { $0.kind == .clientAudioOutput }
        guard events.count == 2, let before = events.first, let after = events.last else {
            return XCTFail("ожидалось два сигнала пары, пришло \(events.count)")
        }
        XCTAssertEqual(after.observedAt, second)
        XCTAssertGreaterThan(after.observedAt, before.observedAt)
        XCTAssertEqual(after.group?.observedAt, after.observedAt)
        XCTAssertEqual(after.group?.pids, [100, 101, 102])
    }
}
