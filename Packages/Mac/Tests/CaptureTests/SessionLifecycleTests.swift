//  К1, К3 — один сеанс, `nothingToCapture`. План MEE-315.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class SessionLifecycleTests: CaptureAsyncTestCase {

    // MARK: - К3. nothingToCapture

    func test_k03_nothingToCapture() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, group: nil, input: .none)
        do {
            _ = try await harness.port.start(request)
            XCTFail("ожидался nothingToCapture")
        } catch CaptureError.nothingToCapture {
            // ожидаемо
        }
        XCTAssertEqual(harness.gateway.tapRequestCount, 0, "ни одного вызова на шов создания tap")
    }

    // MARK: - К1. Один сеанс

    func test_k01_secondStartWhileRunningThrowsAlreadyRunning() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        let second = Harness.request(directory: try Harness.makeDirectory())
        do {
            _ = try await harness.port.start(second)
            XCTFail("ожидался alreadyRunning")
        } catch CaptureError.alreadyRunning {
            // ожидаемо
        }
    }

    func test_k01_stopPauseResumeSetInputWithoutSessionThrowNotRunning() async throws {
        let harness = Harness()
        do {
            _ = try await harness.port.stop()
            XCTFail("ожидался notRunning")
        } catch CaptureError.notRunning {}
        do {
            try await harness.port.pause()
            XCTFail("ожидался notRunning")
        } catch CaptureError.notRunning {}
        do {
            try await harness.port.resume()
            XCTFail("ожидался notRunning")
        } catch CaptureError.notRunning {}
        do {
            try await harness.port.setInput(.none)
            XCTFail("ожидался notRunning")
        } catch CaptureError.notRunning {}
    }

    func test_k01_secondStopThrowsNotRunning() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let session = try await harness.start(directory: directory)
        _ = try await harness.port.stop()
        _ = session
        do {
            _ = try await harness.port.stop()
            XCTFail("ожидался notRunning")
        } catch CaptureError.notRunning {}
    }
}

/// Общий сценарий «успешный старт» для тестов, которым нужен идущий сеанс, а не сам факт
/// успеха: разрешает право системного звука и микрофона немедленно и ждёт возврата `start`.
extension Harness {
    @discardableResult
    func start(
        directory: URL,
        group: ProcessGroup? = ProcessGroup(appKey: "bundle:us.zoom.xos", pids: [111], observedAt: Date()),
        input: InputSelection = .systemDefault
    ) async throws -> CaptureStarted {
        // `group` — явный `nil` здесь означает именно «без группы», а не «не задано»: значение по
        // умолчанию само несёт запасную группу (найденный дефект — `?? ProcessGroup(...)` в теле
        // раньше подменял ЯВНЫЙ nil звонящего той же запасной группой, и К13/К14 не могли
        // проверить путь без группы вообще, пока не подменялись молча).
        let request = Harness.request(directory: directory, group: group, input: input)
        async let started = port.start(request)
        // MEE-374 (аудит MEE-377): gate вместо фикс. паузы — `resolveTap`/`resolveMicrophone`
        // до регистрации continuation теряют разрешение молча (см. `FakeHardwareGateway`).
        if request.group != nil {
            await gateway.awaitTapRequested()
            gateway.resolveTap(with: .created(TapHandle()))
        }
        if request.input != .none {
            await gateway.awaitMicrophoneRequested()
            gateway.resolveMicrophone(with: .opened(MicrophoneHandle(uid: "BuiltInMicrophoneDevice",
                                                                      name: "MacBook Pro Microphone", channelCount: 1)))
        }
        return try await started
    }
}
