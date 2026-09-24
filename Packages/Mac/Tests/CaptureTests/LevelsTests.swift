//  К25, вторая половина — `.levels`: значение по формуле, темп ≤10 Гц по времени ДОСТАВКИ
//  буфера, не по `hostTime` данных. План MEE-315. Возврат MEE-317 (второй круг): реализация
//  существовала без единого теста — этот файл его заводит.
//
//  Возврат MEE-317 (третий круг): прежний коллектор останавливался СЧЁТОМ в два события — это
//  тавтология с самим числом «2» в проверке ниже, реализация без троттлинга вовсе (каждый буфер —
//  своё событие) прошла бы тест неотличимо, просто отдав те же первые два события раньше. Новый
//  коллектор идёт до `.stopped` (терминальное событие потока) и метит КАЖДОЕ `.levels` временем
//  его получения тестом (`Date()` в момент `append`, не `hostTime` данных) — темп проверяется по
//  этим меткам напрямую: интервал между последовательными доставками обязан быть не меньше окна
//  троттлинга. Это ловит и «без троттлинга вовсе», и «троттлинг по счётчику вместо времени»
//  (например, «каждое десятое») — последний тоже уложился бы в разумный ИТОГОВЫЙ счёт, но не
//  выдержал бы промежутки между доставками внутри одновременной пачки.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class LevelsTests: CaptureAsyncTestCase {

    private struct ReceivedLevels {
        let levels: CaptureLevels
        let receivedAt: Date
    }

    func test_k25_levelsThrottledByDeliveryTimeNotByBufferHostTime() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        let stream = harness.port.events()
        let collector = Task { () -> [ReceivedLevels] in
            var collected: [ReceivedLevels] = []
            for await event in stream {
                if case .levels(let levels) = event {
                    collected.append(ReceivedLevels(levels: levels, receivedAt: Date()))
                }
                if case .stopped = event { break }
            }
            return collected
        }

        // 20 буферов с `hostTime`, разнесённым на секунду каждый, кормятся синхронно, без
        // ожидания между вызовами — троттлинг по `hostTime` данных пропустил бы КАЖДЫЙ (интервал
        // больше окна), а по РЕАЛЬНОМУ времени доставки это одна пачка в единицы миллисекунд,
        // намного меньше окна в 100 мс (≤10 Гц) — обязана дать одно доставленное событие, не 20.
        for index in 0..<20 {
            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1,
                                          hostTime: UInt64(1_000 + index * 1_000)))
        }
        // Пауза ДОЛЬШЕ окна троттлинга по реальному времени — следующий буфер обязан дать второе
        // доставленное событие, несмотря на то что его `hostTime` продолжает ту же последовательность.
        try await Task.sleep(nanoseconds: 160_000_000)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 21_000))

        _ = try await harness.port.stop()
        let levels = await collector.value

        // Итоговый счёт: пачка почти одновременной подачи (20 буферов) обязана была схлопнуться
        // в одно доставленное событие, плюс одно из буфера после паузы — граница 6 оставляет
        // запас на побочные события `stop()`/сброса, но остаётся НА ПОРЯДОК меньше 20 — реализация
        // без троттлинга эту границу нарушила бы сразу.
        XCTAssertGreaterThanOrEqual(levels.count, 2, "пачка и отложенный буфер обязаны дать хотя бы два события")
        XCTAssertLessThanOrEqual(levels.count, 6,
                                 "20 буферов почти одновременной подачи обязаны схлопнуться в единицы событий, не 20")

        // Проверка ПО МЕТКАМ ДОСТАВКИ, не по счёту: ни одна пара последовательно доставленных
        // событий не обязана иметь интервал короче окна троттлинга. Возврат MEE-317 (четвёртый
        // круг): порог был занижен до 80 мс «на планировщик» — это допускало до 12,5 события в
        // секунду, а К25 требует не больше 10 (≤100 мс между событиями). Порог — ровно 100 мс, без
        // запаса: `updateLevels` пропускает публикацию, пока `elapsed < 100 мс` от прошлой (её же
        // `Date()`, а не метка теста) — интервал между двумя `Date()` ВНУТРИ порта уже ≥100 мс;
        // метка теста снимается ПОЗЖЕ (после доставки через `AsyncStream`), то есть только
        // добавляет ко времени между метками, никогда не отнимает — порог 100 мс без запаса не
        // может дать ложное падение на верной реализации.
        for pairIndex in 1..<levels.count {
            let gapMs = levels[pairIndex].receivedAt.timeIntervalSince(levels[pairIndex - 1].receivedAt) * 1000
            XCTAssertGreaterThanOrEqual(gapMs, 100,
                                        "интервал между доставленными событиями #\(pairIndex - 1) и #\(pairIndex) "
                                        + "обязан быть не меньше окна троттлинга (100 мс, ≤10 Гц), а не \(gapMs) мс")
        }

        // Независимое ожидаемое значение — не вызов `AudioLevel.value(...)` (это было бы
        // тавтологией с самой проверяемой функцией): амплитуда 0.1 → rms 0.1 (постоянный сигнал)
        // → dBFS = 20·log10(0.1) = −20 → level = (−20 + 60) / 60 = 0.6666... Число посчитано
        // вручную вне кода под тестом, как потребовал возврат.
        let independentExpected: Float = 0.6667
        let firstMic = try XCTUnwrap(levels.first?.levels.mic)
        XCTAssertEqual(firstMic, independentExpected, accuracy: 0.0005,
                       "значение — по формуле max(0, min(1, (dBFS+60)/60)), число посчитано независимо от кода под "
                       + "тестом")
        XCTAssertNil(levels.first?.levels.system, "системный канал не открыт в этом сценарии — nil, не 0")
    }
}
