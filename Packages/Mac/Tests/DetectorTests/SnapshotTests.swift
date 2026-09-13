//  Критерии блоков C и D перечня MEE-75: снимок процессов, инварианты 10, 15, 19, 20 и канарейка
//  приватного символа. К29, К30, К32, К33, К34, К36, К37, К38, К40.
//
//  Сборка снимка вызывается напрямую (шов Ш1): этот файл не импортирует CoreAudio, и тесты
//  исполняются на раннере, где звучащих процессов нет.

import Darwin
import DomainCore
import Foundation
import XCTest
@testable import Detector

final class SnapshotTests: XCTestCase {

    /// Восемь записей К29: пять случаев §4.1, запись с `""`, запись без ответственного и вторая
    /// запись с тем же ключом приложения. Порядок `pid` — вразнобой.
    static let eight: [RawProcessRecord] = [
        Record.make(930, bundle: "com.google.Chrome.helper", responsible: 900),
        Record.make(120, bundle: "com.google.Chrome.helper"),
        Record.make(610, bundle: "com.apple.WebKit.GPU", responsible: 600),
        Record.make(44, bundle: "com.apple.WebKit.GPU"),
        Record.make(710, bundle: "com.apple.WebKit.GPU", responsible: 700),
        Record.make(305, bundle: "", output: true),
        Record.make(812, bundle: "us.zoom.xos"),
        Record.make(900, bundle: "com.google.Chrome", responsible: 900)
    ]

    static let eightBundles: [Int32: String] = [
        900: "com.google.Chrome", 600: "com.apple.Safari", 700: "com.example.OtherWebKitApp"
    ]

    private func build(_ records: [RawProcessRecord], _ bundles: [Int32: String] = eightBundles) -> [AudioProcess] {
        SnapshotBuilder.audioProcesses(from: RawSnapshot(records: records, bundleIdsByPid: bundles),
                                       observedAt: TestWorld.start)
    }

    // MARK: - К29, К30. processes(matching:)

    func test_k29_processesMatching_returnsExactlyMatchedByPid() {
        let result = SnapshotBuilder.processes(build(Self.eight), matching: ["com.google.Chrome", "us.zoom.xos"])
        XCTAssertEqual(result.map(\.pid), [120, 812, 900, 930])
    }

    func test_k30_processesMatching_edges() {
        let snapshot = build(Self.eight)
        XCTAssertEqual(SnapshotBuilder.processes(snapshot, matching: []), [])
        XCTAssertEqual(SnapshotBuilder.processes(snapshot, matching: ["нет.такой.строки"]), [])
    }

    func test_k29_k30_portMethod_goesThroughTheSameRule() async throws {
        let harness = try Harness()
        harness.world.set(Self.eight, bundleIds: Self.eightBundles)
        let matched = try await harness.detector.processes(matching: ["com.google.Chrome", "us.zoom.xos"])
        XCTAssertEqual(matched.map(\.pid), [120, 812, 900, 930])
        let none = try await harness.detector.processes(matching: [])
        XCTAssertEqual(none, [])
    }

    // MARK: - К32, К33. Сборка снимка без CoreAudio; нет двух элементов с одним pid

    func test_k32_builderIsCallableWithoutCoreAudio() {
        XCTAssertEqual(build(Self.eight).count, 8)
    }

    func test_k33_duplicatePid_appearsOnce() {
        let records = [Record.make(77, bundle: "us.zoom.xos"), Record.make(77, bundle: "us.zoom.xos", output: true)]
        let snapshot = build(records)
        XCTAssertEqual(snapshot.map(\.pid), [77])
        XCTAssertEqual(snapshot.first?.isRunningOutput, true)
    }

    /// Живая половина К33. На раннере снимок может оказаться пустым — тогда она зелена
    /// тривиально, и вес несёт половина на фиксированных данных выше.
    func test_k33_liveSnapshot_hasUniquePids() async throws {
        let values = try ReferenceTables.shippedValues()
        let detector = try MeetingDetector(clientRunning: values.clientRunning,
                                           clientAudioOutput: values.clientAudioOutput,
                                           microphoneInUse: values.microphoneInUse,
                                           signalTtlSeconds: values.signalTtlSeconds)
        let live = try await detector.audioProcesses()
        XCTAssertEqual(Set(live.map(\.pid)).count, live.count)
    }

    // MARK: - К34. Инвариант 15: "" → nil

    func test_k34_emptyStrings_becomeNil_blankStringsStay() {
        let records = [
            Record.make(1, bundle: ""),
            Record.make(2, bundle: "us.zoom.xos", responsible: 20),
            Record.make(3, bundle: "", responsible: 30),
            Record.make(4, bundle: "  ")
        ]
        let snapshot = build(records, [20: "", 30: ""])
        guard snapshot.count == 4 else { return XCTFail("в снимке \(snapshot.count) элементов вместо четырёх") }
        XCTAssertNil(snapshot[0].bundleId)
        XCTAssertNil(snapshot[1].responsibleBundleId)
        XCTAssertNil(snapshot[2].bundleId)
        XCTAssertNil(snapshot[2].responsibleBundleId)
        XCTAssertEqual(snapshot[3].bundleId, "  ")
        for process in snapshot {
            XCTAssertNotEqual(process.bundleId, "")
            XCTAssertNotEqual(process.responsibleBundleId, "")
        }
    }

    // MARK: - К36. Ответственный процесс вне снимка аудиопроцессов

    func test_k36_responsibleOutsideSnapshot_isStillResolved() {
        let snapshot = build([Record.make(931, bundle: "com.google.Chrome.helper", responsible: 900, output: true)])
        XCTAssertEqual(snapshot.first?.responsibleBundleId, "com.google.Chrome")
        XCTAssertFalse(snapshot.contains { $0.pid == 900 })
    }

    // MARK: - К37, К40. Инвариант 20 и названная деградация

    static var eightWithoutResponsible: [RawProcessRecord] {
        eight.map { Record.make($0.pid, bundle: $0.bundleId, responsible: nil,
                                output: $0.isRunningOutput, input: $0.isRunningInput) }
    }

    func test_k37_responsibleUnavailable_nilForAll_snapshotWhole() {
        let snapshot = build(Self.eightWithoutResponsible, [:])
        XCTAssertEqual(snapshot.count, 8)
        for process in snapshot {
            XCTAssertNil(process.responsibleBundleId)
            XCTAssertNotEqual(process.bundleId, "")
            XCTAssertNotEqual(process.responsibleBundleId, String(process.pid))
        }
    }

    func test_k37_responsibleUnavailable_portDoesNotThrow() async throws {
        let harness = try Harness()
        harness.world.set(Self.eightWithoutResponsible)
        let snapshot = try await harness.detector.audioProcesses()
        XCTAssertEqual(snapshot.count, 8)
        XCTAssertTrue(snapshot.allSatisfy { $0.responsibleBundleId == nil })
    }

    func test_k40_degradation_safariNotRecognised_noFalseMatch() async throws {
        let harness = try Harness()
        harness.world.set(Self.eightWithoutResponsible)
        let snapshot = try await harness.detector.audioProcesses()
        let detector = harness.detector
        let helper = try XCTUnwrap(snapshot.first { $0.pid == 930 }?.appKey)
        XCTAssertTrue(detector.isBrowser(appKey: helper))
        XCTAssertFalse(detector.isBrowser(appKey: "com.apple.WebKit.GPU"))
        let chrome = try await detector.processes(matching: ["com.google.Chrome"])
        XCTAssertEqual(chrome.map(\.pid), [120, 900, 930])
        XCTAssertFalse(chrome.contains { $0.bundleId == "com.apple.WebKit.GPU" })
        let falseMatches = snapshot.filter { process in
            process.bundleId == "com.apple.WebKit.GPU" && process.appKey.map { detector.isBrowser(appKey: $0) } == true
        }
        XCTAssertEqual(falseMatches, [])
    }

    // MARK: - К38. Канарейка приватного символа — на системе прогона

    /// Доказывает только, что символ жив на системе прогона (раннер `macos-14`), а не у
    /// пользователя: версия раннера отстаёт. На машине пользователя — К39, ручной сеанс.
    func test_k38_responsibilitySymbol_resolvesOnThisSystem() {
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
        XCTAssertNotNil(ProcessIdentity.responsibleFunction)
    }
}
