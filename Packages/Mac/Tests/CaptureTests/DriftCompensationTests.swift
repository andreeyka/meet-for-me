//  К6 — компенсация дрейфа включена на каждой сборке aggregate device безусловно (инвариант 6).
//  План MEE-315. Возврат MEE-317 (24.09): шов обязан отдавать этот аргумент отдельным журналом,
//  а не только сам факт вызова `buildAggregate` — тест утверждает «true» на каждом из них,
//  а не «вызов случился».

import CoreAudio
import DomainCore
import Foundation
import XCTest
@testable import Capture

final class DriftCompensationTests: CaptureAsyncTestCase {

    func test_k06_driftCompensationTrueOnEveryBuildAggregateCall() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        // Десять пересборок подряд (инвалидация tap — тот же tap, новая сборка aggregate,
        // инвариант 4) — «в каждом из десяти» дословно возврата РП. Буфер после каждой
        // инвалидации разрешает `pendingRebuild` (`resolveRebuild`), иначе следующая
        // инвалидация была бы отброшена — `beginRebuild` не начинает вторую пересборку поверх
        // ещё не разрешённой первой. `hostTime` строго возрастает по всему сценарию (как в
        // продакшене — монотонные часы): `beginRebuild` считает `atHostTime - session.hostOrigin`
        // без перевода в знаковый тип (в отличие от `resolveRebuild`), и невозрастающее значение
        // здесь — не сценарий продакшена, а ловушка беззнакового вычитания в самом тесте.
        for index in 0..<10 {
            let invalidatedAt = UInt64(1_000 + index * 100)
            harness.gateway.emit(.tapInvalidated(atHostTime: invalidatedAt))
            try await Task.sleep(nanoseconds: 5_000_000)
            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: invalidatedAt + 50))
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        _ = try await harness.port.stop()

        XCTAssertEqual(harness.gateway.aggregateBuildCount, 11, "старт + десять пересборок")
        XCTAssertTrue(harness.gateway.aggregateBuildArgs.allSatisfy(\.driftCompensation),
                      "компенсация дрейфа — true на каждом вызове buildAggregate без исключений")
    }

    /// Возврат MEE-317 (третий круг): «между сеансами» — второй `start()` после `stop()`
    /// первого, не только повторные пересборки внутри одного сеанса.
    func test_k06_driftCompensationTrueAcrossTwoConsecutiveSessions() async throws {
        let harness = Harness()

        let firstDirectory = try Harness.makeDirectory()
        try await harness.start(directory: firstDirectory)
        _ = try await harness.port.stop()

        let secondDirectory = try Harness.makeDirectory()
        try await harness.start(directory: secondDirectory)
        _ = try await harness.port.stop()

        XCTAssertEqual(harness.gateway.aggregateBuildCount, 2, "по одной сборке на сеанс")
        XCTAssertTrue(harness.gateway.aggregateBuildArgs.allSatisfy(\.driftCompensation),
                      "компенсация дрейфа — true и во втором сеансе, не только в первом")
    }

    /// Возврат MEE-317 (третий круг): значение для НЕ опорного tap — чистая функция
    /// (`AggregateRuntime.nonReferenceDriftCompensationValue`), не требующая живого HAL.
    /// `buildComposition` целиком не тестируема в CI без TCC и настоящего tap-объекта — эта
    /// часть её решения тестируема, и здесь проверена напрямую.
    func test_k06_nonReferenceDriftCompensationValueMatchesFlag() {
        XCTAssertEqual(AggregateRuntime.nonReferenceDriftCompensationValue(true), 1)
        XCTAssertEqual(AggregateRuntime.nonReferenceDriftCompensationValue(false), 0)
    }

    // MARK: - К6 (четвёртый круг) — сборка HAL-словаря из готовых UID

    /// Возврат MEE-317 (четвёртый круг): прежние тесты проверяли только константу, которую порт
    /// передавал шву, ни разу не пройдя через код, реально складывающий HAL-словарь
    /// (`AggregateRuntime.assembleComposition`). Эта функция — чистая (не требует живого HAL, см.
    /// её описание в `CoreAudioAggregate.swift`), тестируется напрямую: у элемента, который НЕ
    /// опорный (микрофон — опорный, tap — нет), `drift` обязан быть 1 при `driftCompensation: true`
    /// — реализация, подставляющая здесь константу `0`, эту проверку не пройдёт.
    func test_k06_assembleCompositionGivesNonReferenceTapDriftOne() {
        let composition = AggregateRuntime.assembleComposition(
            microphoneUID: "mic-uid", defaultOutputUID: nil, tapUID: "tap-uid", driftCompensation: true
        )
        let tapDrift = composition.tapList.first?[kAudioSubTapDriftCompensationKey] as? Int
        XCTAssertEqual(tapDrift, 1, "НЕ опорный tap при driftCompensation=true обязан нести drift=1, "
                       + "не 0 — иначе инвариант 6 («выключить нечем») нарушен молча")
        let micDrift = composition.subDevices.first?[kAudioSubDeviceDriftCompensationKey] as? Int
        XCTAssertEqual(micDrift, 0, "опорный элемент (микрофон) — drift=0 безусловно, см. IR-114")
        XCTAssertEqual(composition.mainUID, "mic-uid")
    }

    /// То же самое без микрофона — опорный элемент становится выходом по умолчанию, tap остаётся
    /// НЕ опорным и обязан получить ту же единицу.
    func test_k06_assembleCompositionWithoutMicrophoneStillGivesNonReferenceTapDriftOne() {
        let composition = AggregateRuntime.assembleComposition(
            microphoneUID: nil, defaultOutputUID: "output-uid", tapUID: "tap-uid", driftCompensation: true
        )
        let tapDrift = composition.tapList.first?[kAudioSubTapDriftCompensationKey] as? Int
        XCTAssertEqual(tapDrift, 1, "НЕ опорный tap — drift=1 и без микрофона в составе")
        let outputDrift = composition.subDevices.first?[kAudioSubDeviceDriftCompensationKey] as? Int
        XCTAssertEqual(outputDrift, 0, "опорный элемент (выход по умолчанию) — drift=0 безусловно")
    }

    /// Без микрофона и без выхода по умолчанию единственным элементом состава остаётся сам tap —
    /// он становится опорным (см. вилку `// СТРОКА: IR-114` в шапке `CoreAudioAggregate.swift`) и
    /// несёт drift=0, несмотря на `driftCompensation: true` — опорному элементу компенсация
    /// относительно себя не полагается ни в одном из двух рогов вилки.
    func test_k06_assembleCompositionTapAloneBecomesReferenceWithDriftZero() {
        let composition = AggregateRuntime.assembleComposition(
            microphoneUID: nil, defaultOutputUID: nil, tapUID: "tap-uid", driftCompensation: true
        )
        let tapDrift = composition.tapList.first?[kAudioSubTapDriftCompensationKey] as? Int
        XCTAssertEqual(tapDrift, 0, "единственный элемент состава — сам себе опорный, drift=0")
        XCTAssertEqual(composition.mainUID, "tap-uid")
    }
}
