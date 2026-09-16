//  К76 перечня MEE-75 (дельта `АР`, пункт плана — дельта `АС`): C-009 v9, инвариант 27 —
//  отношение ДВУХ потоков. Четыре вектора.
//
//  Номер отдельный от К75 по объекту, а не по удобству: К75 говорит о содержимом ОДНОГО потока,
//  К76 — об отношении двух. Часов не требует ни один вектор — это свойство пункта, а не
//  умолчание: `advance(by:)` здесь зовётся только затем, чтобы подтверждение не смешалось с
//  изменением, и ни один ответ от хода часов не зависит.
//
//  Ради чего написан вектор (i): `AsyncStream` доставляет каждый элемент РОВНО ОДНОМУ
//  ожидающему, и реализация, вернувшая на два вызова один и тот же сохранённый поток, законна
//  по сигнатуре — она молча разделит сигналы между потребителями, и каждый посчитает оценку
//  ниже фактической. Проверка, вычитывающая один поток, этого не ловит вовсе, поэтому оба
//  потока читаются до конца и сравниваются с одним и тем же ожидаемым.
//
//  Граница вектора (iv) названа сразу: политики буфера контракт не называет ни словом, поэтому
//  вектор ловит РОВНО буфер короче `N`; буфер длиннее `N` он от неограниченного не отличает.

import DomainCore
import Foundation
import XCTest
@testable import Detector

final class SignalFanOutTests: XCTestCase {

    private static let bundles = SignalStreamTests.chromeBundles
    private static let chrome = SignalStreamTests.chromeMain

    private static func helper(_ pid: Int32, output: Bool = false) -> RawProcessRecord {
        SignalStreamTests.chromeHelper(pid, output: output)
    }

    /// Шаг часов теста — доля запаса подтверждения реализации: ни один ответ этого пункта от
    /// хода часов не зависит, шаг стоит затем, чтобы подтверждение не смешалось с изменением.
    private func step() throws -> TimeInterval {
        let ttl = try ReferenceTables.shippedValues().signalTtlSeconds
        return ConfirmationPolicy.confirmationAge(signalTtlSeconds: ttl) / 5
    }

    // MARK: - (i) Публикация приходит обоим потокам целиком

    func test_k76_vectorI_publicationReachesBothStreamsWhole() async throws {
        let harness = try Harness()
        let first = harness.detector.signals()
        let second = harness.detector.signals()
        harness.world.set([Self.chrome, Self.helper(101, output: true)], bundleIds: Self.bundles)
        try await harness.detector.startObserving()
        let left = await harness.drain(first)
        let right = await harness.drain(second)
        XCTAssertEqual(left.filter { $0.kind == .clientAudioOutput }.count, 1,
                       "первый поток получил публикацию")
        XCTAssertEqual(right, left,
                       "и второй получил её целиком — не одному из двух и не половине каждому")
    }

    // MARK: - (ii) Каждый поток получает СВОЙ снимок — на момент своей подписки

    /// Второй поток подписан после публикации и НИ ОДНОЙ подачи после его подписки не было:
    /// значит пришедшее ему пришло снимком, а не событием. Первый подписан до публикации —
    /// его снимок пуст, и ту же публикацию он получил событием. Снимки двух потоков различны,
    /// и это верный ответ, а не расхождение: одинаковы правило и полнота, а не значение и не
    /// момент. Равенства снимков пункт не требует и требовать не должен.
    func test_k76_vectorII_secondStreamGetsItsOwnSnapshot() async throws {
        let harness = try Harness()
        let first = harness.detector.signals()
        harness.world.set([Record.make(700, bundle: nil, input: true)])
        try await harness.detector.startObserving()
        let second = harness.detector.signals()
        let asEvent = await harness.drain(first)
        let asSnapshot = await harness.drain(second)
        XCTAssertEqual(asEvent.count, 1, "первый поток получил публикацию событием")
        XCTAssertEqual(asSnapshot, asEvent,
                       "второй — снимком, тождественным той же публикации, включая observedAt")
    }

    // MARK: - (iii) Завершение одного потока не влияет ни на другой, ни на наблюдение

    func test_k76_vectorIII_finishedStreamStopsNeitherTheOtherNorObservation() async throws {
        let harness = try Harness()
        let tick = try step()
        let first = harness.detector.signals()
        let second = harness.detector.signals()
        harness.world.set([Self.chrome, Self.helper(101, output: true)], bundleIds: Self.bundles)
        try await harness.detector.startObserving()
        for await _ in first {
            break
        }
        harness.world.set([Self.chrome, Self.helper(101, output: true), Self.helper(102)],
                          bundleIds: Self.bundles)
        harness.world.advance(by: tick)
        harness.driver.fire()
        let events = await harness.drain(second)
        XCTAssertTrue(events.contains { $0.group?.pids == [100, 101, 102] },
                      "второй поток продолжает получать события")
        XCTAssertEqual(harness.driver.stops, 0, "stopObserving не вызывался")
        XCTAssertTrue(harness.driver.isRunning, "наблюдение считает наблюдение, а не подписчиков")
    }

    // MARK: - (iv) Буфер не роняет опубликованного

    func test_k76_vectorIV_bufferDropsNothingBetweenSupplies() async throws {
        let harness = try Harness()
        let tick = try step()
        let supplies = 5
        let stream = harness.detector.signals()
        try await harness.detector.startObserving()
        for index in 0..<supplies {
            harness.world.advance(by: tick)
            let members = (0...index).map { Self.helper(101 + Int32($0), output: true) }
            harness.world.set([Self.chrome] + members, bundleIds: Self.bundles)
            harness.driver.fire()
        }
        let events = await harness.drain(stream).filter { $0.kind == .clientAudioOutput }
        XCTAssertEqual(events.count, supplies,
                       "из потока вычитаны все N значений: ни одно не снято политикой буфера")
    }
}
