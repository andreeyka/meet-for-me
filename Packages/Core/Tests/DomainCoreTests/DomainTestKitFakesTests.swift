//  Пп. 148 и 149: управляющая поверхность `FakeProcessMonitorPort` и `FixedPlatformResolver`,
//  названные §«Фейк для тестов» C-009 дословно.
//
//  Q33 — вектор, без которого пункт проверяет меньше, чем написано: фейк пропускает
//  `MeetingSignal`, который настоящий порт отдать не вправе, и НЕ ПРИВОДИТ ЕГО НИ К ЧЕМУ.
//  Утверждается равенство пришедшего исходному, а не факт прихода.
//
//  Граница пункта, и она повторена здесь потому, что молчание о ней читается как её
//  отсутствие: из поведения фейка не следует ни одного разрешения реализатору `detector`.
//  Механический след этого запрета — К69 перечня MEE-75, и здесь он не дублируется.
//  Счётчик вызовов на фейке есть проверка потребителя, а не идемпотентности реализации порта:
//  идемпотентность — К41, и фейком она не проверяется никогда.

import XCTest
import DomainCore
import DomainTestKit

final class DomainTestKitFakesTests: XCTestCase {

    // MARK: - 148. FakeProcessMonitorPort

    func test_p148_fakeProcessMonitorPort_processListIsSetAndChangedOnTheFly() async throws {
        let port = FakeProcessMonitorPort()
        let first = [
            AudioProcess(pid: 1, bundleId: nil, responsibleBundleId: nil, executableName: "bare",
                         isRunningOutput: false, isRunningInput: false, observedAt: moment),
            AudioProcess(pid: 2, bundleId: "com.google.Chrome.helper", responsibleBundleId: nil,
                         executableName: "helper", isRunningOutput: true, isRunningInput: false,
                         observedAt: moment)
        ]
        port.setProcesses(first)
        let readFirst = try await port.audioProcesses()
        XCTAssertEqual(readFirst, first, "сценарий «приватный символ не разрешился»: ключ у всех nil")
        port.setProcesses([])
        let readSecond = try await port.audioProcesses()
        XCTAssertEqual(readSecond, [], "список меняется на лету")
    }

    func test_p148_fakeProcessMonitorPort_matchingUsesRuleOfSectionFourOne() async throws {
        let port = FakeProcessMonitorPort()
        port.setProcesses([
            AudioProcess(pid: 5, bundleId: "com.google.Chrome.helper", responsibleBundleId: nil,
                         executableName: "helper", isRunningOutput: true, isRunningInput: false,
                         observedAt: moment),
            AudioProcess(pid: 6, bundleId: "com.google.ChromeX", responsibleBundleId: nil,
                         executableName: "other", isRunningOutput: false, isRunningInput: false,
                         observedAt: moment)
        ])
        let matched = try await port.processes(matching: ["com.google.Chrome"])
        XCTAssertEqual(matched.map(\.pid), [5], "точка есть у helper и нет у ChromeX")
    }

    /// Q33: слово «любой» в §«Фейк для тестов» — сознательное, и здесь оно проверено.
    func test_p148_fakeProcessMonitorPort_pushesSignalNoRealPortMayEmit() async throws {
        let port = FakeProcessMonitorPort()
        let stream = port.signals()
        let broken = MeetingSignal(
            kind: .clientRunning, weight: 1.5, pid: 900, bundleId: nil,
            group: nil, provider: nil, meetingId: nil, observedAt: moment)
        let repeated = MeetingSignal(
            kind: .clientAudioOutput, weight: 0.8, pid: 900, bundleId: nil,
            group: ProcessGroup(appKey: "com.google.Chrome", pids: [900, 900, 120],
                                observedAt: moment),
            provider: nil, meetingId: nil, observedAt: moment)
        port.emit(broken)
        port.emit(repeated)
        port.finishSignals()
        var received: [MeetingSignal] = []
        for await signal in stream { received.append(signal) }
        XCTAssertEqual(received, [broken, repeated], "значение доходит неизменённым")
        XCTAssertEqual(received.first?.weight, 1.5, "зажатия в 0...1 фейк не делает")
        XCTAssertNil(received.first?.group, "clientRunning без группы прошёл как есть")
        XCTAssertEqual(received.last?.group?.pids, [900, 900, 120], "повторы и порядок сохранены")
    }

    func test_p148_fakeProcessMonitorPort_startObservingThrowsWhatTestAsked() async {
        let port = FakeProcessMonitorPort()
        port.failStartObserving(with: .permissionRequired(.systemAudioRecording))
        await assertThrows(port, expected: .permissionRequired(.systemAudioRecording))
        port.failStartObserving(with: .permissionRequired(.microphone))
        await assertThrows(port, expected: .permissionRequired(.microphone))
        port.failStartObserving(with: nil)
        do {
            try await port.startObserving()
        } catch {
            XCTFail("отказ снят, а порт всё равно бросил: \(error)")
        }
    }

    func test_p148_fakeProcessMonitorPort_countsStartAndStopCalls() async throws {
        let port = FakeProcessMonitorPort()
        XCTAssertEqual(port.startObservingCallCount, 0)
        XCTAssertEqual(port.stopObservingCallCount, 0)
        try await port.startObserving()
        try await port.startObserving()
        await port.stopObserving()
        XCTAssertEqual(port.startObservingCallCount, 2)
        XCTAssertEqual(port.stopObservingCallCount, 1)
    }

    // MARK: - 149. FixedPlatformResolver

    func test_p149_fixedPlatformResolver_answersFromDictionaryOnly() throws {
        let zoom = try joinInfo(provider: "zoom", url: "https://zoom.us/j/1",
                                clients: ["us.zoom.xos"])
        let meet = try joinInfo(provider: "meet", url: "https://meet.google.com/abc", clients: [])
        let resolver = FixedPlatformResolver(answers: ["ссылка зума": zoom, "ссылка мита": meet])
        XCTAssertEqual(resolver.resolve(text: "ссылка зума", source: .bodyText), zoom)
        XCTAssertEqual(resolver.resolve(text: "ссылка мита", source: .bodyText), meet)
        XCTAssertNil(resolver.resolve(text: "чего в словаре нет", source: .bodyText))
    }

    func test_p149_fixedPlatformResolver_derivesClientsAndBrowsersWithoutTables() throws {
        let zoom = try joinInfo(provider: "zoom", url: "https://zoom.us/j/1",
                                clients: ["us.zoom.xos"])
        let resolver = FixedPlatformResolver(answers: ["z": zoom],
                                             browsers: ["com.google.Chrome"])
        XCTAssertEqual(resolver.clientBundleIds(for: "zoom"), ["us.zoom.xos"])
        XCTAssertEqual(resolver.clientBundleIds(for: "teams"), [])
        XCTAssertEqual(resolver.allKnownClientBundleIds(), ["us.zoom.xos"])
        XCTAssertEqual(resolver.provider(forAppKey: "us.zoom.xos"), "zoom")
        XCTAssertNil(resolver.provider(forAppKey: "com.google.Chrome"))
        XCTAssertTrue(resolver.isBrowser(appKey: "com.google.Chrome.helper"))
        XCTAssertFalse(resolver.isBrowser(appKey: "com.google.ChromeX"))
    }

    // MARK: - Оснастка

    private func assertThrows(_ port: FakeProcessMonitorPort,
                              expected: ProcessMonitorError,
                              file: StaticString = #filePath,
                              line: UInt = #line) async {
        do {
            try await port.startObserving()
            XCTFail("ожидался отказ \(expected)", file: file, line: line)
        } catch let error as ProcessMonitorError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("ожидался ProcessMonitorError, получено \(error)", file: file, line: line)
        }
    }

    private func joinInfo(provider: String, url: String, clients: [String]) throws -> JoinInfo {
        JoinInfo(provider: provider, joinUrl: try makeURL(url), meetingId: nil, passcode: nil,
                 clientBundleIds: clients, source: .bodyText)
    }

    private var moment: Date { date(milliseconds: 1_757_000_000_000) }
}
