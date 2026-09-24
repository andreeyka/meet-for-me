//  К25, вторая половина — `.levels`: значение по формуле, темп ≤10 Гц по времени ДОСТАВКИ
//  буфера, не по `hostTime` данных. План MEE-315. Возврат MEE-317 (второй круг): реализация
//  существовала без единого теста — этот файл его заводит.
//
//  Возврат MEE-317 (третий круг), доп. РП по аудиту MEE-377 (24.09 18:05): момент доставки —
//  инжектируемые часы теста (`ManualClock`, `AudioCaptureImpl.now`), а не настоящий `Date()` и
//  не реальная пауза. Часы стоят на месте все 20 буферов пачки (троттлинг по `hostTime` данных
//  пропустил бы КАЖДЫЙ — интервал `hostTime` больше окна) и сдвигаются явно за окно троттлинга
//  перед последним буфером — счёт событий детерминирован точным числом, не диапазоном на
//  случай шума планировщика: «без троттлинга вовсе» дал бы 21 событие, «троттлинг по счётчику»
//  (например, «каждое десятое» на 21 буфере) — 3, верная реализация — ровно 2.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class LevelsTests: CaptureAsyncTestCase {

    func test_k25_levelsThrottledByDeliveryTimeNotByBufferHostTime() async throws {
        let clock = ManualClock()
        let harness = Harness(now: clock.now)
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        let stream = harness.port.events()
        let collector = Task { () -> [CaptureLevels] in
            var collected: [CaptureLevels] = []
            for await event in stream {
                if case .levels(let levels) = event { collected.append(levels) }
                if case .stopped = event { break }
            }
            return collected
        }

        // 20 буферов с `hostTime`, разнесённым на секунду каждый, — часы теста стоят на месте
        // все 20 вызовов, троттлинг по времени ДОСТАВКИ обязан схлопнуть их в одно событие.
        for index in 0..<20 {
            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1,
                                          hostTime: UInt64(1_000 + index * 1_000)))
        }
        // Часы сдвинуты явно ЗА окно троттлинга (100 мс) — следующий буфер обязан дать второе
        // событие, несмотря на то что его `hostTime` продолжает ту же последовательность.
        clock.advance(by: 0.101)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 21_000))

        _ = try await harness.port.stop()
        let levels = await collector.value

        XCTAssertEqual(levels.count, 2, "пачка почти одновременной подачи схлопнулась в одно доставленное "
                       + "событие, плюс одно после явного сдвига часов за окно троттлинга")

        // Независимое ожидаемое значение — не вызов `AudioLevel.value(...)` (это было бы
        // тавтологией с самой проверяемой функцией): амплитуда 0.1 → rms 0.1 (постоянный сигнал)
        // → dBFS = 20·log10(0.1) = −20 → level = (−20 + 60) / 60 = 0.6666... Число посчитано
        // вручную вне кода под тестом, как потребовал возврат.
        let independentExpected: Float = 0.6667
        let firstMic = try XCTUnwrap(levels.first?.mic)
        XCTAssertEqual(firstMic, independentExpected, accuracy: 0.0005,
                       "значение — по формуле max(0, min(1, (dBFS+60)/60)), число посчитано независимо от кода под "
                       + "тестом")
        XCTAssertNil(levels.first?.system, "системный канал не открыт в этом сценарии — nil, не 0")
    }
}
