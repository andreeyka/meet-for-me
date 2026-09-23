//  К25, вторая половина — `.levels`: значение по формуле, темп ≤10 Гц по времени ДОСТАВКИ
//  буфера, не по `hostTime` данных. План MEE-315. Возврат MEE-317 (второй круг): реализация
//  существовала без единого теста — этот файл его заводит.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class LevelsTests: CaptureAsyncTestCase {

    func test_k25_levelsThrottledByDeliveryTimeNotByBufferHostTime() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        let collector = Task { () -> [CaptureLevels] in
            var collected: [CaptureLevels] = []
            for await event in harness.port.events() {
                if case .levels(let levels) = event {
                    collected.append(levels)
                    if collected.count >= 2 { break }
                }
            }
            return collected
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        // 20 буферов с `hostTime`, разнесённым на секунду каждый, — троттлинг по `hostTime`
        // данных пропустил бы КАЖДЫЙ (интервал больше окна). Кормятся синхронно, без ожидания
        // между вызовами: по РЕАЛЬНОМУ времени доставки это одна пачка в несколько миллисекунд,
        // намного меньше окна в 100 мс (≤10 Гц) — обязано дать одно событие, не двадцать.
        for index in 0..<20 {
            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1,
                                          hostTime: UInt64(1_000 + index * 1_000)))
        }
        // Дать первому событию дойти до коллектора и убедиться, что второе не пришло рано —
        // окно троттлинга (100 мс) ещё не истекло по реальному времени.
        try await Task.sleep(nanoseconds: 50_000_000)

        // После паузы ДОЛЬШЕ окна троттлинга по реальному времени — следующий буфер обязан дать
        // второе событие, несмотря на то что его `hostTime` продолжает ту же последовательность.
        try await Task.sleep(nanoseconds: 110_000_000)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 21_000))

        let levels = await collector.value
        XCTAssertEqual(levels.count, 2,
                       "пачка из 20 буферов почти одновременно дала одно событие (не 20) — троттлинг по доставке")
        let expected = AudioLevel.value(fromSamples: [Float](repeating: 0.1, count: 480))
        let firstMic = try XCTUnwrap(levels[0].mic)
        XCTAssertEqual(firstMic, expected, accuracy: 0.0001, "значение — по формуле max(0, min(1, (dBFS+60)/60))")
        XCTAssertNil(levels[0].system, "системный канал не открыт в этом сценарии — nil, не 0")
    }
}
