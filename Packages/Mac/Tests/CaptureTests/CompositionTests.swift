//  К4, К5, К7 — tap переживает пересборку, пересобирается только aggregate, нормализация
//  формата. План MEE-315.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class CompositionTests: CaptureAsyncTestCase {

    // MARK: - К4. Tap переживает пересборку

    func test_k04_tapCreatedOnceAcrossFiveRebuilds() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        for index in 0..<5 {
            let hostTime = UInt64(1_000 + index * 100)
            harness.gateway.emit(.microphoneFormatChanged(channelCount: index.isMultiple(of: 2) ? 1 : 3,
                                                           atHostTime: hostTime))
            try await Task.sleep(nanoseconds: 5_000_000)
            // Пересборка остаётся «в процессе» (pendingRebuild), пока не пришёл первый буфер новой
            // сборки — resolveRebuild зовётся из handleBuffer. Без этого следующий emit молча
            // отбрасывается guard'ом beginRebuild (pendingRebuild == nil), и рebuild не считается.
            harness.gateway.feed(.samples(.mic, frameCount: 480,
                                          channelCount: index.isMultiple(of: 2) ? 1 : 3, hostTime: hostTime + 10))
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(harness.gateway.tapRequestCount, 1, "tap создан ровно один раз за сеанс")
        XCTAssertEqual(harness.gateway.aggregateBuildCount, 6, "1 старт + 5 пересборок")
        XCTAssertTrue(harness.gateway.releasedTaps.isEmpty, "tap не освобождался ни разу")
    }

    // MARK: - К5. Пересобирается только aggregate

    func test_k05_deviceChangeRebuildsAggregateOnlyNotTap() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)
        let tapCallsBefore = harness.gateway.tapRequestCount
        let aggregateCallsBefore = harness.gateway.aggregateBuildCount

        harness.gateway.emit(.microphoneChanged(
            MicrophoneHandle(uid: "airpods", name: "AirPods Pro", channelCount: 1), atHostTime: 2_000
        ))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(harness.gateway.tapRequestCount, tapCallsBefore, "устройство сменилось — tap не трогается")
        XCTAssertEqual(harness.gateway.aggregateBuildCount, aggregateCallsBefore + 1, "ровно одна пересборка aggregate")
    }

    // MARK: - К7. Нормализация к объявленному формату

    func test_k07_formatChangeNormalizesToDeclaredTrackFormat() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()

        let collector = Task { () -> [CaptureEvent] in
            var collected: [CaptureEvent] = []
            for await event in harness.port.events() {
                collected.append(event)
                if case .discontinuity = event { break }
            }
            return collected
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        // Формат микрофона по умолчанию (Harness.request) — 48 кГц/1 канал.
        let started = try await harness.start(directory: directory)
        XCTAssertEqual(started.tracks.first { $0.channel == .mic }?.channelCount, 1)

        // Источник переключился на 3 канала (voice processing в чужом процессе) посреди сеанса.
        harness.gateway.emit(.microphoneFormatChanged(channelCount: 3, atHostTime: 5_000))
        try await Task.sleep(nanoseconds: 20_000_000)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 3, hostTime: 5_050))
        try await Task.sleep(nanoseconds: 20_000_000)

        let events = await collector.value
        // Возврат MEE-317 (24.09): не только факт события — реальные `from`/`to`, а не любые
        // значения того же кейса. `from` — формат ДО смены (1 канал, тот, с которым открылся
        // микрофон), `to` — новый (3 канала), а не то же самое значение дважды (что и было бы
        // недостатком: `session.request.micFormat` не меняется никогда, такая проверка сошла бы
        // при полностью сломанной подстановке `old`/`new`).
        let formatChange = events.compactMap { event -> (from: TrackFormat, to: TrackFormat)? in
            if case .inputFormatChanged(let from, let to) = event { return (from, to) }
            return nil
        }.first
        let change = try XCTUnwrap(formatChange, "ожидался inputFormatChanged")
        XCTAssertEqual(change.from, TrackFormat(sampleRate: 48_000, channelCount: 1), "формат до смены — исходный")
        XCTAssertEqual(change.to, TrackFormat(sampleRate: 48_000, channelCount: 3), "формат после смены — новый")

        let lastDiscontinuity = events.last { if case .discontinuity = $0 { return true }; return false }
        guard case .discontinuity(let discontinuity)? = lastDiscontinuity
        else { return XCTFail("ожидался discontinuity") }
        XCTAssertEqual(discontinuity.reason, .rebuild)

        let manifest = try await harness.port.stop()
        let micTrack = try XCTUnwrap(manifest.tracks.first { $0.channel == .mic })
        XCTAssertEqual(micTrack.channelCount, 1, "CaptureStarted.tracks — объявленный формат не меняется")
        let frames = TrackFile.framesOnDisk(at: directory.appendingPathComponent(micTrack.fileName), channelCount: 1)
        XCTAssertGreaterThan(frames, 0, "данные после смены формата дописаны, приведённые к объявленному")
    }

    // MARK: - К7 (продолжение). Само приведение каналов — не только факт записи

    /// Возврат MEE-317 (24.09): предыдущий тест проверял только `frames > 0` — этого достаточно и
    /// для сломанного приведения (например, если бы `ChannelAdapter` писал нули или обрезал не тот
    /// канал). Здесь — различимые по каналам значения и точное сравнение массивов на выходе,
    /// отдельно для сужения (3→1, требует выбора канала) и расширения (1→2, требует дублирования).
    func test_k07_channelAdapterProducesExactSamplesNotJustNonzeroCount() {
        // 2 кадра, 3 канала, значения различимы по каналу и по кадру: канал c, кадр f → c*10 + f.
        let threeChannel: [Float] = [0, 1, 10, 11, 20, 21]
        let narrowed = ChannelAdapter.adapt(threeChannel, frameCount: 2, from: 3, to: 1)
        // Целевой единственный канал берёт источник 0 (`min(channel, sourceChannels-1)`) — те же
        // значения, что были у канала 0, не среднее и не канал 1/2.
        XCTAssertEqual(narrowed, [0, 1], "сужение 3→1 берёт канал 0 дословно")

        let oneChannel: [Float] = [5, 7]
        let widened = ChannelAdapter.adapt(oneChannel, frameCount: 2, from: 1, to: 2)
        // Расширение дублирует единственный источник на оба целевых канала — не нули, не один
        // из кадров потерян.
        XCTAssertEqual(widened, [5, 5, 7, 7], "расширение 1→2 дублирует источник на оба канала")
    }
}
