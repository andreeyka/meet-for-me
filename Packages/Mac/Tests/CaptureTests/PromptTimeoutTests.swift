//  К15, К16, К17, К18 — пределы промптов и наблюдение исхода права. План MEE-315.
//
//  «Виртуальное время шва»: `ManualDeadline.expireNow()` не ждёт настоящих 45 секунд —
//  критерии проверяют, что порт СЧИТАЕТ таймаут наступившим и реагирует, а не что часы идут.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class PromptTimeoutTests: CaptureAsyncTestCase {

    // MARK: - К15. Системный промпт: таймаут

    func test_k15_systemAudioPromptTimeout() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, input: .none)

        // MEE-374 (аудит MEE-377): `expireNow()` — «текущий И ВСЕ СЛЕДУЮЩИЕ вызовы `wait`
        // возвращаются немедленно» (см. её же докстринг в `TestSupport.swift`) — вызов до того,
        // как `wait(seconds:)` внутри `race()` реально стартовал, не теряется и не гонка.
        async let started = harness.port.start(request)
        harness.deadline.expireNow()

        do {
            _ = try await started
            XCTFail("ожидался systemAudioPromptTimedOut")
        } catch CaptureError.systemAudioPromptTimedOut(let waited) {
            XCTAssertEqual(waited, AudioCaptureLimits.systemAudioPromptWaitSeconds)
        }
        XCTAssertEqual(try filesIn(directory), [], "файлов не создано")
        // Реализация с ошибочным пределом (например, 1 с вместо 45) отличалась бы только тут —
        // `waited` выше несёт КОНСТАНТУ, названную самой реализацией, а не измеренное число.
        XCTAssertEqual(harness.deadline.waitedSeconds, [AudioCaptureLimits.systemAudioPromptWaitSeconds],
                       "предел системного промпта передан шву дословно — 45 с, один вызов")
    }

    // MARK: - К16. Микрофонный промпт: таймаут

    func test_k16_microphonePromptTimeout() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, group: nil, input: .systemDefault)

        async let started = harness.port.start(request)
        harness.deadline.expireNow()

        do {
            _ = try await started
            XCTFail("ожидался microphonePromptTimedOut")
        } catch CaptureError.microphonePromptTimedOut(let waited) {
            XCTAssertEqual(waited, AudioCaptureLimits.microphonePromptWaitSeconds)
        }
        XCTAssertEqual(try filesIn(directory), [], "файлов не создано")
        XCTAssertEqual(harness.deadline.waitedSeconds, [AudioCaptureLimits.microphonePromptWaitSeconds],
                       "предел микрофонного промпта передан шву дословно — 45 с, один вызов")
    }

    /// Независимость двух пределов: у обоих одно и то же ЧИСЛО (45 с — оба константы контракта),
    /// поэтому независимость проверяется не значением, а тем, что это ДВА раздельных вызова
    /// `wait(seconds:)` — по одному на свою гонку, а не общий предел на двоих. Право системного
    /// звука отвечает значением сразу; гонка микрофона стартует своим чередом уже после и несёт
    /// свой отдельный вызов предела — оба видны в записанном порядке.
    func test_k15_k16_bothLimitsAreIndependentCalls() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, group: .init(appKey: "us.zoom.xos", pids: [1],
                                                                          observedAt: Date()), input: .systemDefault)

        async let started = harness.port.start(request)
        await harness.gateway.awaitTapRequested()
        let tap = TapHandle()
        harness.gateway.resolveTap(with: .created(tap))
        harness.deadline.expireNow()

        do {
            _ = try await started
            XCTFail("ожидался microphonePromptTimedOut")
        } catch CaptureError.microphonePromptTimedOut {}

        XCTAssertEqual(
            harness.deadline.waitedSeconds,
            [AudioCaptureLimits.systemAudioPromptWaitSeconds, AudioCaptureLimits.microphonePromptWaitSeconds],
            "два раздельных вызова предела, не один общий: право и микрофон гонятся порознь"
        )
    }

    // MARK: - К17. Позднее срабатывание после таймаута

    func test_k17_lateTapGrantIsDestroyedNotResumingSession() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, input: .none)

        // §«Право на системный звук», п. 3: исход, пришедший после предела, всё равно публикуется
        // `permissionObserved` — тем же путём, что и уложившийся в предел (возврат MEE-317, 24.09:
        // прежде тест проверял только уничтожение tap, не сам факт публикации события).
        let stream = harness.port.events()
        let collector = Task { () -> CaptureEvent? in
            for await event in stream {
                if case .permissionObserved = event { return event }
            }
            return nil
        }

        async let started = harness.port.start(request)
        harness.deadline.expireNow()
        do {
            _ = try await started
            XCTFail("ожидался таймаут")
        } catch CaptureError.systemAudioPromptTimedOut {}

        let lateTap = TapHandle()
        await harness.gateway.awaitTapRequested()
        harness.gateway.resolveTap(with: .created(lateTap))
        // MEE-374 (аудит MEE-377): `handleLateTap` освобождает tap из СОБСТВЕННОГО фонового
        // `Task` (`AudioCaptureImplStart.swift`) — `awaitTapReleased()` ждёт именно этого факта,
        // не оценки времени, в которое он мог бы уложиться.
        await harness.gateway.awaitTapReleased()

        XCTAssertEqual(harness.gateway.releasedTaps, [lateTap], "tap, пришедший с опозданием, уничтожен")
        XCTAssertEqual(harness.gateway.aggregateBuildCount, 0, "сеанс сам по себе не поднялся")

        guard case .permissionObserved(let kind, let status)? = await collector.value
        else { return XCTFail("ожидался permissionObserved на позднем пути") }
        XCTAssertEqual(kind, .systemAudioRecording)
        XCTAssertEqual(status, .granted, "поздний tap создался — исход тот же, что у уложившегося в предел")
    }

    func test_k17_lateMicrophoneGrantIsClosed() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, group: nil, input: .systemDefault)

        async let started = harness.port.start(request)
        harness.deadline.expireNow()
        do {
            _ = try await started
            XCTFail("ожидался таймаут")
        } catch CaptureError.microphonePromptTimedOut {}

        let lateMic = MicrophoneHandle(uid: "late", name: "Late Mic", channelCount: 1)
        await harness.gateway.awaitMicrophoneRequested()
        harness.gateway.resolveMicrophone(with: .opened(lateMic))
        await harness.gateway.awaitMicrophoneReleased()

        XCTAssertEqual(harness.gateway.releasedMicrophones, [lateMic])
        XCTAssertEqual(harness.gateway.aggregateBuildCount, 0)
    }

    // MARK: - К18. Наблюдение исхода права

    func test_k18_permissionObservedOnGrantAndDenyOnlyForSystemAudio() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        // Успешный старт публикует `permissionObserved(.granted)` первым событием (возврат
        // MEE-317: после него, ДО `started(_)`, теперь идёт ещё и `capturedProcessesChanged` —
        // инвариант 12(а)); цикл берёт первые два счётом и завершается сам, не полагаясь на
        // отмену задачи поверх AsyncStream (риск незавершённого потока — шов теста, не порт).
        let stream = harness.port.events()
        let collector = Task { () -> [CaptureEvent] in
            var collected: [CaptureEvent] = []
            for await event in stream {
                collected.append(event)
                if collected.count >= 2 { break }
            }
            return collected
        }

        _ = try await harness.start(directory: directory)
        let events = await collector.value

        let observed = events.compactMap { event -> (PermissionKind, PermissionStatus)? in
            if case .permissionObserved(let kind, let status) = event { return (kind, status) }
            return nil
        }
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.0, .systemAudioRecording)
        XCTAssertEqual(observed.first?.1, .granted)
    }

    func test_k18_deniedSystemAudioPublishesPermissionObserved() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, input: .none)

        // Отказ права публикует ровно одно событие — permissionObserved(.denied) — и на этом
        // start() бросает: `.started` не следует, цикл берёт единственное событие счётом.
        let stream = harness.port.events()
        let collector = Task { () -> [CaptureEvent] in
            var collected: [CaptureEvent] = []
            for await event in stream {
                collected.append(event)
                if collected.count >= 1 { break }
            }
            return collected
        }

        async let started = harness.port.start(request)
        await harness.gateway.awaitTapRequested()
        harness.gateway.resolveTap(with: .permissionDenied)
        do {
            _ = try await started
            XCTFail("ожидался systemAudioDenied")
        } catch CaptureError.systemAudioDenied {}

        let events = await collector.value
        let observed = events.compactMap { event -> PermissionStatus? in
            if case .permissionObserved(.systemAudioRecording, let status) = event { return status }
            return nil
        }
        XCTAssertEqual(observed, [.denied])
    }

    /// К18 возврата части 1: из микрофонных исходов был проверен только успех — оба отказных
    /// исхода имеют собственный код ошибки (инвариант 16: у микрофона `note` не через
    /// `permissionObserved`, статус читается публично) и обязаны быть проверены тем же путём.
    func test_k18_microphoneDeniedThrowsMicrophoneDenied() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, group: nil, input: .systemDefault)

        async let started = harness.port.start(request)
        await harness.gateway.awaitMicrophoneRequested()
        harness.gateway.resolveMicrophone(with: .permissionDenied)

        do {
            _ = try await started
            XCTFail("ожидался microphoneDenied")
        } catch CaptureError.microphoneDenied {}
        XCTAssertEqual(try filesIn(directory), [], "файлов не создано")
    }

    func test_k18_microphonePromptTimeoutThrowsMicrophonePromptTimedOut() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, group: nil, input: .systemDefault)

        async let started = harness.port.start(request)
        harness.deadline.expireNow()

        do {
            _ = try await started
            XCTFail("ожидался microphonePromptTimedOut")
        } catch CaptureError.microphonePromptTimedOut(let waited) {
            XCTAssertEqual(waited, AudioCaptureLimits.microphonePromptWaitSeconds)
        }
        XCTAssertEqual(try filesIn(directory), [], "файлов не создано")
    }

    private func filesIn(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }
}
