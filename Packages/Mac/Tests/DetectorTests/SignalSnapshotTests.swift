//  К75 перечня MEE-75 (дельта `АР`, пункт плана — дельта `АС`): C-009 v9, инвариант 26 —
//  содержимое потока в момент подписки. Семь векторов, номер один: объект у всех один — снимок,
//  уходящий подписавшемуся.
//
//  Пункт разрезан по векторам на семь тестов: выбор исполнителя, место и вход при любом выборе
//  те же. Причина резать — поимённый исход в аннотации CI: упавший вектор обязан называться
//  сам, а не прятаться за именем пункта.
//
//  Снимки подаёт тест точкой подачи Ш4, момент снимка приходит значением (Ш4 (ii)), часы ведёт
//  тест (Ш6 (i)), МЕСТО ПОДПИСКИ НАЗВАНО В КАЖДОМ ВЕКТОРЕ — оно часть входа (Ш4 (iii)).
//  Числа секунд здесь нет ни одного: всякая величина выражена долей либо кратным
//  `signalTtlSeconds` ПОЛУЧЕННОЙ таблицы (точка приёма Ш5), а не литералом.
//
//  Чего вектора не проверяют, названо, потому что молчание о границе читается как её
//  отсутствие: соблюдения самого срока подтверждения — К73 (i) и (iv); поведения второго
//  потока — К76; политики буфера — К76 (iv); дедупликации неизменившегося состояния — К45.
//  Очерёдности ВНУТРИ снимка не утверждает ни один вектор: инвариант 26 её не требует, и
//  утверждение о ней краснело бы на верной реализации.

import DomainCore
import Foundation
import XCTest
@testable import Detector

final class SignalSnapshotTests: XCTestCase {

    private static let bundles = SignalStreamTests.chromeBundles
    private static let chrome = SignalStreamTests.chromeMain

    private static func helper(_ pid: Int32, output: Bool = false) -> RawProcessRecord {
        SignalStreamTests.chromeHelper(pid, output: output)
    }

    /// Процесс с открытым входом и без ключа приложения: пара «`microphoneInUse` + `pid`».
    /// Она несёт РОВНО ОДИН сигнал на снимок — у группы их два и больше, и вектор, которому
    /// нужна одна публикация, строится на ней, а не на группе.
    private static func listening(_ pid: Int32) -> RawProcessRecord {
        Record.make(pid, bundle: nil, input: true)
    }

    /// Срок `signalTtlSeconds` ПОЛУЧЕННОЙ таблицы (точка приёма Ш5, Ш6 (ii)) и шаг часов теста —
    /// доля запаса подтверждения реализации (Ш6 (iii)): на таком шаге подтверждений в окно
    /// вектора не попадает ни одного. Числом ни та ни другая величина здесь не задана.
    private func window() throws -> (ttl: TimeInterval, step: TimeInterval) {
        let ttl = try ReferenceTables.shippedValues().signalTtlSeconds
        return (ttl, ConfirmationPolicy.confirmationAge(signalTtlSeconds: ttl) / 5)
    }

    // MARK: - (i) Подписка, когда публикаций не было ни одной

    func test_k75_vectorI_subscriptionBeforeAnyPublication_snapshotIsEmpty() async throws {
        let harness = try Harness()
        let span = try window()
        let stream = harness.detector.signals()
        try await harness.detector.startObserving()
        harness.world.advance(by: span.step)
        let moment = harness.world.now()
        harness.world.set([Self.chrome, Self.helper(101, output: true)],
                          bundleIds: Self.bundles, observedAt: moment)
        harness.driver.fire()
        let events = await harness.drain(stream)
        XCTAssertFalse(events.isEmpty, "снимок, поданный после подписки, дошёл")
        XCTAssertEqual(events.first?.observedAt, moment,
                       "первым пришло событие снимка, поданного ПОСЛЕ подписки")
        XCTAssertTrue(events.allSatisfy { $0.observedAt == moment },
                      "снимка при подписке не было ни одного элемента")
    }

    // MARK: - (ii) Публикация, затем подписка внутри срока

    func test_k75_vectorII_snapshotRepeatsPublicationWithItsOwnObservedAt() async throws {
        let harness = try Harness()
        let span = try window()
        let published = harness.detector.signals()
        let moment = harness.world.now()
        harness.world.set([Self.listening(700)], observedAt: moment)
        try await harness.detector.startObserving()
        harness.world.advance(by: span.ttl / 2)
        let stream = harness.detector.signals()
        let expected = await harness.drain(published)
        let snapshot = await harness.drain(stream)
        XCTAssertEqual(expected.count, 1, "пара микрофона опубликована один раз")
        XCTAssertEqual(snapshot, expected,
                       "снимок тождествен публикации, включая observedAt: подписка её не молодит")
        XCTAssertEqual(snapshot.first?.observedAt, moment)
    }

    // MARK: - (iii) Три перехода одной пары без единого подписчика

    func test_k75_vectorIII_snapshotCarriesTheLastOfThreeTransitions() async throws {
        let harness = try Harness()
        let span = try window()
        harness.world.set([], bundleIds: [:])
        try await harness.detector.startObserving()
        var moments: [Date] = []
        for pids in [[Int32(101)], [101, 102], [101, 102, 103]] {
            harness.world.advance(by: span.step)
            let moment = harness.world.now()
            moments.append(moment)
            harness.world.set([Self.chrome] + pids.map { Self.helper($0, output: true) },
                              bundleIds: Self.bundles, observedAt: moment)
            harness.driver.fire()
        }
        let stream = harness.detector.signals()
        let snapshot = await harness.drain(stream).filter { $0.kind == .clientAudioOutput }
        XCTAssertEqual(snapshot.count, 1, "в снимке один сигнал пары — последний по observedAt")
        XCTAssertEqual(snapshot.first?.observedAt, moments.last)
        XCTAssertEqual(snapshot.first?.group?.pids, [100, 101, 102, 103])
        XCTAssertFalse(snapshot.contains { moments.dropLast().contains($0.observedAt) },
                       "предыдущие два перехода не возвращаются")
    }

    // MARK: - (iv) Две разные пары, обе в сроке

    func test_k75_vectorIV_snapshotCarriesOneSignalPerPair() async throws {
        let harness = try Harness()
        let span = try window()
        harness.world.set([Self.chrome, Self.helper(101, output: true)], bundleIds: Self.bundles)
        try await harness.detector.startObserving()
        harness.world.advance(by: span.step)
        harness.world.set([Self.chrome, Self.helper(101, output: true), Self.listening(700)],
                          bundleIds: Self.bundles)
        harness.driver.fire()
        let stream = harness.detector.signals()
        let snapshot = await harness.drain(stream)
        XCTAssertEqual(snapshot.filter { $0.kind == .clientAudioOutput }.count, 1,
                       "пара «clientAudioOutput + com.google.Chrome» — одним сигналом")
        XCTAssertEqual(snapshot.filter { $0.kind == .microphoneInUse && $0.pid == 700 }.count, 1,
                       "пара «microphoneInUse + pid» — одним сигналом")
    }

    // MARK: - (v) Пара, чей срок вышел, и пара в сроке

    func test_k75_vectorV_pairOlderThanTtl_doesNotReturnToTheSnapshot() async throws {
        let harness = try Harness()
        let span = try window()
        harness.world.set([Self.listening(700)])
        try await harness.detector.startObserving()
        harness.world.set([], bundleIds: [:])
        harness.world.advance(by: span.ttl + span.step)
        harness.driver.fire()
        harness.world.set([Self.chrome, Self.helper(101, output: true)], bundleIds: Self.bundles)
        harness.world.advance(by: span.step)
        harness.driver.fire()
        let stream = harness.detector.signals()
        let snapshot = await harness.drain(stream)
        XCTAssertTrue(snapshot.filter { $0.kind == .microphoneInUse }.isEmpty,
                      "выпавший по сроку не возвращается: вернуть его может лишь новая публикация")
        XCTAssertEqual(snapshot.filter { $0.kind == .clientAudioOutput }.count, 1,
                       "пара, чья публикация моложе срока, в снимке есть")
    }

    // MARK: - (vi) Снимок уходит прежде события, наступившего после подписки

    func test_k75_vectorVI_snapshotGoesBeforeTheEventAfterSubscription() async throws {
        let harness = try Harness()
        let span = try window()
        harness.world.set([Self.chrome, Self.helper(101, output: true)], bundleIds: Self.bundles)
        try await harness.detector.startObserving()
        harness.world.advance(by: span.step)
        let stream = harness.detector.signals()
        harness.world.set([Self.chrome, Self.helper(101, output: true), Self.helper(102)],
                          bundleIds: Self.bundles)
        harness.world.advance(by: span.step)
        harness.driver.fire()
        let events = await harness.drain(stream).filter { $0.kind == .clientAudioOutput }
        guard events.count == 2 else {
            return XCTFail("ожидались снимок и событие перехода, пришло \(events.count)")
        }
        XCTAssertEqual(events.first?.group?.pids, [100, 101], "первым — снимок, не событие")
        XCTAssertEqual(events.last?.group?.pids, [100, 101, 102], "вторым — событие перехода")
    }

    // MARK: - (vii) Разностный прогон: чужие подписки срока не продлевают

    /// Сравниваются два прогона ОДНОГО корпуса, различающиеся ровно тремя чужими подписками, и
    /// сравнивается разность разрывов, а не их величина. Вектор ловит реализацию, считающую
    /// подписку поводом подтвердить состояние, — то есть переносящую срок инварианта 24 на
    /// чужие подписки.
    func test_k75_vectorVII_foreignSubscriptionsShiftNoGapInTheFirstStream() async throws {
        let plain = try await confirmationGaps(withForeignSubscriptions: false)
        let disturbed = try await confirmationGaps(withForeignSubscriptions: true)
        XCTAssertFalse(plain.isEmpty, "корпус держит состояние дольше срока: подтверждения в потоке есть")
        XCTAssertEqual(plain, disturbed,
                       "снимок сроком инварианта 24 не является и его не продлевает")
    }

    /// Корпус: состояние держится `3 × signalTtlSeconds` шагами меньше запаса реализации.
    /// Первый поток подписан ДО первой публикации и держится всё время.
    private func confirmationGaps(withForeignSubscriptions: Bool) async throws -> [TimeInterval] {
        let harness = try Harness()
        let span = try window()
        let steps = Int((3 * span.ttl / span.step).rounded(.up))
        let stream = harness.detector.signals()
        harness.world.set([Self.chrome, Self.helper(101, output: true)], bundleIds: Self.bundles)
        try await harness.detector.startObserving()
        for index in 0..<steps {
            harness.world.advance(by: span.step)
            harness.driver.fire()
            if withForeignSubscriptions, [2, 5, 8].contains(index) {
                _ = harness.detector.signals()
            }
        }
        let pair = await harness.drain(stream).filter { $0.kind == .clientAudioOutput }
        return zip(pair, pair.dropFirst()).map { $1.observedAt.timeIntervalSince($0.observedAt) }
    }
}
