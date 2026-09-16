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

    /// К73, вектор (v). Прогон 3: момент снимка РАЗВЕДЁН с показанием часов.
    ///
    /// Без этого вектора клауза (i) зелена по построению: при равных моменте снимка и показании
    /// часов разрыв по `observedAt` тождественно равен разрыву между публикациями, и реализация,
    /// отсчитывающая срок от момента СОБСТВЕННОЙ публикации, проходит клаузу на любом входе — не
    /// потому, что исполняет её, а потому, что вход не различает две величины. Тот же класс, что
    /// [MEE-254](https://linear.app/easypto/issue/MEE-254) снял для К51 и К62, этажом ниже.
    ///
    /// Разрыв между моментами публикации в этом прогоне меньше срока и без того: краснеет ровно
    /// разрыв по `observedAt`, и краснеет он у той реализации, которую вектор обязан ловить.
    func test_k73_vectorV_laggingSnapshotMoment_deadlineIsMeasuredByObservedAt() async throws {
        try await confirmationRun(bytes: nil, laggingFirstSnapshot: true)
    }

    /// Без номера критерия: драйвер приложения сам зовёт шаги, и подтверждения идут без теста.
    /// Реальные часы для К73 не годятся (шапка «Инвариантов» C-009), поэтому здесь проверяется только
    /// проводка `TimerDriver` на сроке в доли секунды — число подтверждений, а не величина разрывов.
    ///
    /// Мир взят НА ЧАСАХ МАШИНЫ, и это несущее: `advance(by:)` здесь звать не с кем — шаги идут по
    /// часам машины, а `moment` мира стоял бы на `TestWorld.start`. Тогда возраст в решении о сроке
    /// был бы разностью двух несоизмеримых шкал — порядка ста тридцати суток при сроке в доли
    /// секунды, — «пора» наступало бы на КАЖДОМ шаге при любом сроке, и тест доказывал бы только
    /// то, что драйвер зовёт шаги. С часами машины момент снимка и «сколько сейчас» приходят от
    /// одного источника, как их берёт живая работа, и срок снова решает, когда идёт подтверждение.
    func test_timerDriver_confirmsHoldingStateWithoutTestSteps() async throws {
        let world = TestWorld(clock: SystemClock())
        world.set(chrome, bundleIds: SignalStreamTests.chromeBundles)
        let values = try ReferenceTables.received(
            SignalWeights.values(from: ReferenceTables.signalWeights(signalTtlSeconds: 1)))
        let shortTtl = try ReceivedValues(clientRunning: values.clientRunning,
                                          clientAudioOutput: values.clientAudioOutput,
                                          microphoneInUse: values.microphoneInUse,
                                          signalTtlSeconds: values.signalTtlSeconds / 5)
        let environment = SignalEngine.Environment(source: world, clock: world, driver: TimerDriver(),
                                                   preferredStep: Harness.preferredStep)
        let detector = MeetingDetector(tables: try ReferenceTables.tables(), values: shortTtl,
                                       environment: environment)
        let stream = detector.signals()
        try await detector.startObserving()
        // Сторож: если драйвер не зовёт шаги, поток закрывается через пять секунд, а не висит вечно.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            detector.observation.finishSignalStreams()
        }
        var confirmations = 0
        for await signal in stream where signal.kind == .clientAudioOutput {
            confirmations += 1
            if confirmations == 3 { break }
        }
        watchdog.cancel()
        await detector.stopObserving()
        XCTAssertEqual(confirmations, 3, "публикация и два подтверждения пришли от драйвера приложения")
    }

    /// Держит состояние `3 × signalTtlSeconds` шагами меньше запаса реализации, затем убирает процесс.
    ///
    /// `laggingFirstSnapshot` — вектор (v). Первый снимок пары подаётся с моментом, отстающим от
    /// показания часов БОЛЬШЕ, чем `signalTtlSeconds` минус наибольший разрыв между публикациями,
    /// который реализация себе позволяет на этом шаге; все последующие снимки идут по часам, то
    /// есть отставание убывает ОДНОКРАТНО — `observedAt` остаётся строго возрастающим, и К62
    /// входом не нарушается. **Числа секунд здесь не написано ни одного:** отставание выражено
    /// через `signalTtlSeconds` загруженной таблицы и наблюдаемый запас реализации (Ш6 (iii)).
    /// Числом его размерить нельзя — запас не константа реализации: он меняется от одной строки
    /// оснастки, и вектор, размеренный числом, был бы зелен на той самой реализации, которую
    /// обязан ловить.
    private func confirmationRun(bytes: Data?, laggingFirstSnapshot: Bool = false) async throws {
        let harness = try harness(bytes)
        let ttl = try bytes.map { Double(try SignalWeights.values(from: $0).signalTtlSeconds) }
            ?? ReferenceTables.shippedValues().signalTtlSeconds
        let confirmationAge = ConfirmationPolicy.confirmationAge(signalTtlSeconds: ttl)
        let stepLength = confirmationAge / 5
        // Подтверждение идёт на первом шаге, на котором возраст достиг запаса, — отсюда наибольший
        // разрыв между публикациями при этом шаге. Отставание берётся на один шаг больше порога,
        // чтобы вектор не стоял на самой границе.
        let widestPublicationGap = (confirmationAge / stepLength).rounded(.up) * stepLength
        let lag = ttl - widestPublicationGap + stepLength
        let stream = harness.detector.signals()
        let firstMoment: Date? = laggingFirstSnapshot
            ? harness.world.now().addingTimeInterval(-lag) : nil
        harness.world.set(chrome, bundleIds: SignalStreamTests.chromeBundles, observedAt: firstMoment)
        if let firstMoment {
            XCTAssertNotEqual(firstMoment, harness.world.now(), "момент снимка и часы разведены входом")
            XCTAssertLessThan(lag + stepLength, ttl, "вектор обязан оставлять верную реализацию зелёной")
            XCTAssertGreaterThan(widestPublicationGap + lag, ttl, "вектор обязан ловить отсчёт от публикации")
        }
        try await harness.detector.startObserving()
        if laggingFirstSnapshot {
            // Дальше момент снимка равен показанию часов: отставание убывает ровно один раз.
            harness.world.set(chrome, bundleIds: SignalStreamTests.chromeBundles)
        }
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
