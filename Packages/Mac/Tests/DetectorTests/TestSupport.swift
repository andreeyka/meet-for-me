//  Оснастка тестов модуля `detector`.
//
//  * `ReferenceTables` — байты таблиц, из которых тест строит правила чистой функцией
//    `RuleTables.build` (шов Ш2 (ii)) и значения весов чистой функцией `domain-core`
//    `SignalWeights.values(from:)` (Ш2 (ii) стороны `domain-core`, Ш5 (i)).
//  * `TestWorld` — источник снимков и часы, которыми распоряжается тест (швы Ш4 и Ш6).
//  * `ManualDriver` — драйвер наблюдения, шаг которого зовёт тест; возврат из `fire()` значит,
//    что всё, что шаг должен был опубликовать, уже в потоке (Ш4 (iii), Ш6 (i)).
//
//  Реализацию порта целиком оснастка не подменяет: сравнение состояний, дедупликацию, срок
//  подтверждения, веса и провайдера исполняет настоящий `SignalEngine`.

import DomainCore
import Foundation
import XCTest
@testable import Detector

// MARK: - Таблицы

enum ReferenceTables {

    static let zoomEntry = """
    {"provider": "zoom", "displayName": "Zoom", "priority": 10, "urlPatterns": [
      {"hostSuffix": "zoom.us", "pathRegex": "^/(j|s|w)/(?<meetingId>[0-9]+)",
       "meetingIdQueryKey": null, "passcodeQueryKey": "pwd"}]}
    """

    static let meetEntry = """
    {"provider": "meet", "displayName": "Google Meet", "priority": 20, "urlPatterns": [
      {"hostSuffix": "meet.google.com", "pathRegex": "^/(?<meetingId>[a-z]{3}-[a-z]{4}-[a-z]{3})",
       "meetingIdQueryKey": null, "passcodeQueryKey": null}]}
    """

    static let acmeEntry = """
    {"provider": "acme", "displayName": "Acme", "priority": 5, "urlPatterns": [
      {"hostSuffix": "acme.example", "pathRegex": "^/(?<meetingId>[0-9]+)",
       "meetingIdQueryKey": null, "passcodeQueryKey": null}]}
    """

    static let browsers = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "ru.yandex.desktop.yandex-browser"
    ]

    static let clientEntries = [
        #"{"provider": "zoom", "bundleIds": ["us.zoom.xos"], "browserFallback": true}"#,
        #"{"provider": "teams", "bundleIds": ["com.microsoft.teams2"], "browserFallback": true}"#,
        #"{"provider": "meet", "bundleIds": [], "browserFallback": true}"#
    ]

    static func providers(_ entries: [String] = [zoomEntry, meetEntry]) -> Data {
        Data(#"{"schemaVersion": 1, "providers": [\#(entries.joined(separator: ","))]}"#.utf8)
    }

    static func clients(browsers: [String] = browsers, entries: [String] = clientEntries) -> Data {
        let rows = browsers.map { "\"\($0)\"" }.joined(separator: ",")
        let records = entries.joined(separator: ",")
        return Data(#"{"schemaVersion": 1, "browsers": [\#(rows)], "clients": [\#(records)]}"#.utf8)
    }

    static func tables(providers: Data = providers(), clients: Data = clients()) throws -> RuleTables {
        try RuleTables.build(providers: providers, clients: clients)
    }

    /// Байты таблицы весов §5 с подменёнными числами.
    static func signalWeights(clientRunning: Double = 0.4, clientAudioOutput: Double = 0.8,
                              microphoneInUse: Double = 0.4, signalTtlSeconds: Int = 60) -> Data {
        Data("""
        {"schemaVersion": 1, "signalTtlSeconds": \(signalTtlSeconds), "weights": {
          "calendarWindow": 0.2, "clientRunning": \(clientRunning),
          "microphoneInUse": \(microphoneInUse), "clientAudioOutput": \(clientAudioOutput)}}
        """.utf8)
    }

    /// Значения, принятые портом ровно так, как их отдаёт `domain-core`.
    static func received(_ weights: SignalWeights) throws -> ReceivedValues {
        try ReceivedValues(clientRunning: weights.weight(for: .clientRunning),
                           clientAudioOutput: weights.weight(for: .clientAudioOutput),
                           microphoneInUse: weights.weight(for: .microphoneInUse),
                           signalTtlSeconds: Double(weights.signalTtlSeconds))
    }

    /// Штатный набор: значения таблицы весов, поставленной собранным `domain-core`.
    static func shippedValues() throws -> ReceivedValues {
        try received(SignalWeights.current())
    }
}

// MARK: - Мир и часы

final class TestWorld: ProcessSnapshotSource, ObservationClock, @unchecked Sendable {

    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private let lock = NSLock()
    private var records: [RawProcessRecord] = []
    private var bundleIds: [Int32: String] = [:]
    private var moment = TestWorld.start

    func set(_ records: [RawProcessRecord], bundleIds: [Int32: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        self.records = records
        self.bundleIds = bundleIds
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        moment = moment.addingTimeInterval(seconds)
    }

    func readSnapshot() throws -> RawSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RawSnapshot(records: records, bundleIdsByPid: bundleIds)
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return moment
    }
}

final class ManualDriver: ObservationDriver, @unchecked Sendable {

    private let lock = NSLock()
    private var step: (@Sendable () -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var interval: TimeInterval?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return step != nil
    }

    func start(interval: TimeInterval, step: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        starts += 1
        self.interval = interval
        self.step = step
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stops += 1
        step = nil
    }

    /// Один шаг наблюдения. Возвращает управление, когда шаг обработан целиком.
    func fire() {
        lock.lock()
        let current = step
        lock.unlock()
        current?()
    }
}

// MARK: - Порт на подставленном мире

struct Harness {

    static let preferredStep: TimeInterval = 1

    let world = TestWorld()
    let driver = ManualDriver()
    let detector: MeetingDetector

    init(tables: RuleTables? = nil, values: ReceivedValues? = nil) throws {
        let environment = SignalEngine.Environment(source: world, clock: world, driver: driver,
                                                   preferredStep: Harness.preferredStep)
        detector = MeetingDetector(tables: try tables ?? ReferenceTables.tables(),
                                   values: try values ?? ReferenceTables.shippedValues(),
                                   environment: environment)
    }

    /// Завершает выданные потоки и читает поток до конца: ровно то, что было опубликовано.
    func drain(_ stream: AsyncStream<MeetingSignal>) async -> [MeetingSignal] {
        detector.observation.finishSignalStreams()
        var collected: [MeetingSignal] = []
        for await signal in stream {
            collected.append(signal)
        }
        return collected
    }
}

// MARK: - Записи снимка

enum Record {

    static func make(_ pid: Int32, bundle: String?, responsible: Int32? = nil,
                     output: Bool = false, input: Bool = false) -> RawProcessRecord {
        RawProcessRecord(pid: pid, bundleId: bundle, responsiblePid: responsible, executableName: "proc\(pid)",
                         isRunningOutput: output, isRunningInput: input)
    }
}

// MARK: - Исходники модуля

struct SourceFile {
    let name: String
    let text: String
}

enum DetectorSources {

    static func directory(_ relative: String, from file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    static func swiftFiles(in relative: String) throws -> [SourceFile] {
        let root = directory(relative)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { name in
            SourceFile(name: name, text: try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8))
        }
    }

    static func sources() throws -> [SourceFile] { try swiftFiles(in: "Sources/Detector") }
    static func tests() throws -> [SourceFile] { try swiftFiles(in: "Tests/DetectorTests") }
}
