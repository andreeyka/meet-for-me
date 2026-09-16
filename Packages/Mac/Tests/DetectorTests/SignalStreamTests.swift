//  Критерии блока E перечня MEE-75: поток сигналов, наблюдение, группы.
//  К41—К44, К46, К48—К53, К61, К62.
//
//  Снимки подаёт тест точкой подачи Ш4, ход времени — часами Ш6; всё остальное исполняет
//  настоящий `SignalEngine`. Окно каждого критерия короче срока подтверждения: часы теста
//  между шагами не доходят до половины `signalTtlSeconds`.
//
//  МЕСТО ПОДПИСКИ ЕСТЬ ЧАСТЬ ВХОДА, а не оснастка (Ш4 (iii) в редакции `АР` перечня; способ
//  `С` плана в редакции `АС`). С C-009 v9 подписавшемуся уходит снимок актуального
//  (инвариант 26), поэтому число и состав элементов потока зависят от того, где стоит
//  подписка. Критерий, чей ответ считает элементы потока, называет место сам — здесь это К43
//  (между переходами №1 и №2) и К44 (после трёх переходов). У ОСТАЛЬНЫХ подписка стоит ДО
//  ПЕРВОЙ ПОДАЧИ: это умолчание шва, а не выбор автора теста, и оно стоит в каждом тесте
//  первой строкой после `Harness()`.
//
//  У К51 и К62 предмет — сам `observedAt`, и они задают момент снимка ТРЕТЬИМ аргументом
//  `world.set(_:bundleIds:observedAt:)`, отличным от показания часов (Ш4 (ii)). Пока этого
//  входа не было, обе величины в реализации были одной переменной, и оба критерия сверяли её
//  саму с собой: реализация, подставляющая момент публикации вместо момента снимка, проходила
//  их зелёными. Отсюда в обоих стоит `XCTAssertNotEqual` с моментом публикации — утверждение,
//  которое такая реализация провалить обязана.

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
        let stream = harness.detector.signals()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101)], bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        try await harness.detector.startObserving()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true)], bundleIds: Self.chromeBundles)
        harness.world.advance(by: 1)
        harness.driver.fire()
        let events = await harness.drain(stream)
        XCTAssertEqual(events.filter { $0.kind == .clientAudioOutput }.count, 1,
                       "переход состояния дал ровно одно событие, не два")
        XCTAssertEqual(harness.driver.starts, 1, "второй драйвер наблюдения не заведён")
    }

    func test_k42_startStopStart_eventArrives() async throws {
        let harness = try Harness()
        let stream = harness.detector.signals()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101)], bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        await harness.detector.stopObserving()
        try await harness.detector.startObserving()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true)], bundleIds: Self.chromeBundles)
        harness.world.advance(by: 1)
        harness.driver.fire()
        let events = await harness.drain(stream)
        XCTAssertEqual(events.filter { $0.kind == .clientAudioOutput }.count, 1,
                       "после второго старта событие приходит")
    }

    // MARK: - К43, К44. Снимок при подписке и события после неё; наблюдение без подписчиков

    /// К43 в редакции дельты `АР` перечня MEE-75 и дельты `АС` плана MEE-126 (C-009 v9,
    /// инвариант 26). Прежняя редакция утверждала обратное — «№1 не получено», — и была зелена
    /// на реализации, снимка не отдававшей.
    ///
    /// Место подписки — часть входа: она стоит между переходом №1 и переходом №2 ТОЙ ЖЕ пары.
    /// Пары разные дали бы в снимке два сигнала, и вектор перестал бы отличать снимок от
    /// предыстории. Окно ведут часы теста (Ш6 (i)) и не доходят ни до `signalTtlSeconds` от
    /// №1, ни до запаса подтверждения реализации (Ш6 (iii)): подтверждений в него не попадает
    /// ни одного.
    ///
    /// Сравнение — ТОЖДЕСТВОМ события, включая `observedAt`, а не равенством значения: ровно
    /// им краснеет реализация, ставящая снимку свежий `observedAt`, — третий исход, названный
    /// и отвергнутый изданием v9. Поток `early` здесь оснастка, а не утверждение о втором
    /// подписчике (это К76): он даёт опубликованные значения, с которыми сверяется поздний.
    ///
    /// Счёт ведётся по паре, названной входом. Клауза критерия «третьего события в потоке нет»
    /// читается по ней же: группа `com.google.Chrome` публикует ещё и пару
    /// «`clientRunning` + `com.google.Chrome`», и переход №2 меняет состав `pids` у обеих.
    func test_k43_subscriberGetsSnapshotOfTransitionOne_thenTransitionTwo() async throws {
        let harness = try Harness()
        let ttl = try ReferenceTables.shippedValues().signalTtlSeconds
        let step = ConfirmationPolicy.confirmationAge(signalTtlSeconds: ttl) / 4
        let early = harness.detector.signals()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101)], bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true)], bundleIds: Self.chromeBundles)
        harness.world.advance(by: step)
        harness.driver.fire()
        let stream = harness.detector.signals()
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true), Self.chromeHelper(102)],
                          bundleIds: Self.chromeBundles)
        harness.world.advance(by: step)
        harness.driver.fire()
        XCTAssertLessThan(2 * step, ConfirmationPolicy.confirmationAge(signalTtlSeconds: ttl),
                          "окно короче запаса: ни одного подтверждения в него не попало")
        let published = await harness.drain(early).filter { $0.kind == .clientAudioOutput }
        let events = await harness.drain(stream).filter { $0.kind == .clientAudioOutput }
        guard published.count == 2, events.count == 2 else {
            return XCTFail("опубликовано \(published.count) переходов пары, получено \(events.count)")
        }
        XCTAssertEqual(events.first, published.first, "первым — снимок: №1 тождеством, включая observedAt")
        XCTAssertEqual(events.last, published.last, "вторым — событие перехода №2, и третьего у пары нет")
        XCTAssertEqual(events.last?.group?.pids, [100, 101, 102], "№2 — та же пара, изменившийся состав")
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
        let stream = harness.detector.signals()
        harness.world.set(full, bundleIds: Self.chromeBundles)
        try await harness.detector.startObserving()
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
        // Снимок снят в `moment`, а часы к шагу публикации ушли вперёд: величины две, и
        // задаёт их тест двумя разными входами.
        let moment = TestWorld.start
        harness.world.advance(by: 42)
        harness.world.set([Record.make(900, bundle: "com.google.Chrome", responsible: 900),
                           Record.make(120, bundle: "com.google.Chrome.helper", responsible: 900, output: true),
                           Record.make(900, bundle: "com.google.Chrome", responsible: 900)],
                          bundleIds: [900: "com.google.Chrome"], observedAt: moment)
        let published = harness.world.now()
        XCTAssertNotEqual(moment, published, "момент снимка и момент публикации разведены входом")
        try await harness.detector.startObserving()
        let events = await harness.drain(stream)
        XCTAssertFalse(events.isEmpty)
        for signal in events {
            let group = try XCTUnwrap(signal.group)
            XCTAssertEqual(group.pids, [120, 900])
            XCTAssertTrue(group.pids.contains(try XCTUnwrap(signal.pid)))
            XCTAssertEqual(group.observedAt, moment)
            XCTAssertEqual(signal.observedAt, moment)
            XCTAssertNotEqual(group.observedAt, published, "в group.observedAt уехал момент публикации")
            XCTAssertNotEqual(signal.observedAt, published, "в signal.observedAt уехал момент публикации")
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
        // Два снимка с РАЗНЫМИ моментами, и ход часов между шагами им не равен: `observedAt`
        // обязан вырасти на шаг снимка, а не на шаг часов.
        let first = TestWorld.start
        let second = first.addingTimeInterval(7)
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true)],
                          bundleIds: Self.chromeBundles, observedAt: first)
        try await harness.detector.startObserving()
        harness.world.advance(by: 21)
        harness.world.set([Self.chromeMain, Self.chromeHelper(101, output: true), Self.chromeHelper(102)],
                          bundleIds: Self.chromeBundles, observedAt: second)
        let published = harness.world.now()
        XCTAssertNotEqual(second, published, "момент снимка и момент публикации разведены входом")
        harness.driver.fire()
        let events = await harness.drain(stream).filter { $0.kind == .clientAudioOutput }
        guard events.count == 2, let before = events.first, let after = events.last else {
            return XCTFail("ожидалось два сигнала пары, пришло \(events.count)")
        }
        XCTAssertEqual(after.observedAt, second)
        XCTAssertNotEqual(after.observedAt, published, "в observedAt уехал момент публикации")
        XCTAssertGreaterThan(after.observedAt, before.observedAt)
        XCTAssertEqual(after.group?.observedAt, after.observedAt)
        XCTAssertEqual(after.group?.pids, [100, 101, 102])
    }
}
