//  Критерий 63 перечня MEE-74: удержание не переживает перезапуск приложения.
//
//  Дочерний процесс-испытуемый — тот же бандл тестов, запущенный `xctest` на один пробный
//  тест с переменной окружения: он берёт `.recording` и ждёт, пока его не убьют `kill -9`.
//  Тот же приём, которым спайк MEE-8 закрывал R9.

import Foundation
import XCTest
@testable import Permissions

final class PowerRestartTests: XCTestCase {

    static let probeFlag = "MEETFORME_POWER_PROBE"
    static let probeTest = "PermissionsTests.PowerRestartTests/test_c63_probe_holdsRecordingUntilKilled"

    /// Тело дочернего процесса. В обычном прогоне переменной нет, и тест ничего не делает.
    func test_c63_probe_holdsRecordingUntilKilled() async {
        guard ProcessInfo.processInfo.environment[Self.probeFlag] == "1" else { return }
        let power = SystemPower()
        let token = await power.beginActivity(reason: .recording, label: "probe")
        withExtendedLifetime(token) { Thread.sleep(forTimeInterval: 120) }
    }

    func test_c63_holdDoesNotSurviveKill9() throws {
        let first = try launchProbe()
        defer { first.terminate() }
        XCTAssertTrue(waitUntil(30) { PowerAssertions.holdsPreventIdleSleep(first.processIdentifier) },
                      "дочерний процесс \(first.processIdentifier) взял удержание сна")
        kill(first.processIdentifier, SIGKILL)
        first.waitUntilExit()
        XCTAssertTrue(waitUntil(5) { PowerAssertions.assertions(of: first.processIdentifier).isEmpty },
                      "после kill -9 удержаний старого pid нет")

        let second = try launchProbe()
        defer { second.terminate() }
        XCTAssertTrue(waitUntil(30) { PowerAssertions.holdsPreventIdleSleep(second.processIdentifier) },
                      "перезапущенный процесс взял своё удержание")
        XCTAssertTrue(PowerAssertions.assertions(of: first.processIdentifier).isEmpty, "старому pid ничего не прилипло")
        kill(second.processIdentifier, SIGKILL)
        second.waitUntilExit()
        XCTAssertTrue(waitUntil(5) { PowerAssertions.assertions(of: second.processIdentifier).isEmpty })
    }

    private func launchProbe() throws -> Process {
        let arguments = ProcessInfo.processInfo.arguments
        let executable = arguments.first.map(URL.init(fileURLWithPath:))
        guard let executable, executable.lastPathComponent == "xctest" else {
            throw XCTSkip("тесты запущены не через xctest: \(arguments.first ?? "?")")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-XCTest", Self.probeTest, Bundle(for: PowerRestartTests.self).bundlePath]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.probeFlag] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
