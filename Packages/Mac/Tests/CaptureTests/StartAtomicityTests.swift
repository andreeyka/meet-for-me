//  К2 — старт атомарен. План MEE-315.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class StartAtomicityTests: CaptureAsyncTestCase {

    func test_k02_successOpensBothDeclaredTracks() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let started = try await harness.start(directory: directory)

        XCTAssertEqual(Set(started.tracks.map(\.channel)), [.mic, .system])
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertTrue(files.contains("audio-mic.caf"))
        XCTAssertTrue(files.contains("audio-system.caf"))
    }

    /// Отказ на «второй половине» (сборка aggregate — уже после того, как оба трека открылись
    /// внутри реализации) не оставляет ни одного файла и не считает сеанс начатым.
    func test_k02_failureAfterFilesOpenedLeavesNoFilesAndNoSession() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        harness.gateway.aggregateBuildError = CaptureError.systemUnavailable(message: "diagnostic")

        do {
            _ = try await harness.start(directory: directory)
            XCTFail("ожидался systemUnavailable")
        } catch CaptureError.systemUnavailable {
            // ожидаемо
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, [], "ни одного файла — старт атомарен")

        do {
            _ = try await harness.port.stop()
            XCTFail("ожидался notRunning")
        } catch CaptureError.notRunning {
            // сеанс не считается начатым
        }
    }
}
