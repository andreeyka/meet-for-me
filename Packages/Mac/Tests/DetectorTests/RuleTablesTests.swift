//  Критерии блока A перечня MEE-75: таблицы-ресурсы, инициализация, битая таблица.
//  К1, К2, К5, К6, К11, К12, К24.

import DomainCore
import Foundation
import XCTest
@testable import Detector

final class RuleTablesTests: XCTestCase {

    // MARK: - К1, К2. Добавление провайдера и клиента — правка JSON, а не Swift

    func test_k01_providerAddedToJSON_isResolvedWithoutSwiftChange() throws {
        let tables = try ReferenceTables.tables(
            providers: ReferenceTables.providers([ReferenceTables.zoomEntry, ReferenceTables.meetEntry,
                                                  ReferenceTables.acmeEntry]))
        let info = try XCTUnwrap(LinkResolver.resolve(text: "https://acme.example/12345", source: .bodyText,
                                                     tables: tables))
        XCTAssertEqual(info.provider, "acme")
        XCTAssertEqual(info.meetingId, "12345")
        XCTAssertEqual(info.source, .bodyText)
    }

    func test_k02_clientAddedToJSON_isKnown() throws {
        let acme = #"{"provider": "acme", "bundleIds": ["com.acme.desk"], "browserFallback": false}"#
        let tables = try ReferenceTables.tables(
            clients: ReferenceTables.clients(entries: ReferenceTables.clientEntries + [acme]))
        XCTAssertEqual(tables.clientBundleIds(for: "acme"), ["com.acme.desk"])
        XCTAssertTrue(tables.allKnownClientBundleIds().contains("com.acme.desk"))
    }

    // MARK: - К5, К11. Битая таблица: инициализация бросает, объекта нет

    /// Входы (a)—(f) К5 для `providers.json`.
    static let brokenProviders: [String: String] = [
        "a: невалидный JSON": #"{"schemaVersion": 1, "providers": ["#,
        "b: schemaVersion 2": #"{"schemaVersion": 2, "providers": []}"#,
        "c: нет schemaVersion": #"{"providers": []}"#,
        "d: повторяющийся ключ": #"{"schemaVersion": 1, "schemaVersion": 1, "providers": []}"#,
        "e: число не конечно": #"{"schemaVersion": 1, "providers": [{"provider": "x", "displayName": "X", "#
            + #""priority": 1e400, "urlPatterns": []}]}"#,
        "f: нет обязательного поля": #"{"schemaVersion": 1, "providers": [{"provider": "x", "priority": 1, "#
            + #""urlPatterns": []}]}"#
    ]

    /// Входы (a)—(f) К5 для `clients.json`.
    static let brokenClients: [String: String] = [
        "a: невалидный JSON": #"{"schemaVersion": 1, "browsers": "#,
        "b: schemaVersion 2": #"{"schemaVersion": 2, "browsers": [], "clients": []}"#,
        "c: нет schemaVersion": #"{"browsers": [], "clients": []}"#,
        "d: повторяющийся ключ": #"{"schemaVersion": 1, "browsers": [], "browsers": [], "clients": []}"#,
        "e: число не конечно": #"{"schemaVersion": 1e400, "browsers": [], "clients": []}"#,
        "f: нет обязательного поля": #"{"schemaVersion": 1, "browsers": [], "#
            + #""clients": [{"provider": "zoom", "bundleIds": []}]}"#
    ]

    /// Вход (i) К5 — спор ролей, парой строк и в обе стороны: прямой и зеркальный.
    static let roleConflicts: [String: Data] = [
        "i: клиент — потомок браузера": conflict(browser: "com.google.Chrome", client: "com.google.Chrome.acmeclient"),
        "i: браузер — потомок клиента": conflict(browser: "com.google.Chrome.beta", client: "com.google.Chrome"),
        "i: равенство строк": conflict(browser: "com.acme.desk", client: "com.acme.desk")
    ]

    static func conflict(browser: String, client: String) -> Data {
        ReferenceTables.clients(
            browsers: [browser],
            entries: [#"{"provider": "acme", "bundleIds": ["\#(client)"], "browserFallback": false}"#])
    }

    func test_k05_k11_brokenTable_refusesToBuild_andNoDetectorExists() throws {
        for (name, text) in Self.brokenProviders.sorted(by: { $0.key < $1.key }) {
            XCTAssertThrowsError(try RuleTables.build(providers: Data(text.utf8), clients: ReferenceTables.clients()),
                                 "providers.json, \(name)")
        }
        for (name, text) in Self.brokenClients.sorted(by: { $0.key < $1.key }) {
            XCTAssertThrowsError(try RuleTables.build(providers: ReferenceTables.providers(), clients: Data(text.utf8)),
                                 "clients.json, \(name)")
        }
        for (name, bytes) in Self.roleConflicts.sorted(by: { $0.key < $1.key }) {
            XCTAssertThrowsError(try RuleTables.build(providers: ReferenceTables.providers(), clients: bytes), name) {
                guard case RuleTableError.roleConflict = $0 else {
                    return XCTFail("\(name): ожидался спор ролей, пришло \($0)")
                }
            }
        }
    }

    /// К11, вторая половина: отказ `domain-core` на битой таблице весов. Порт без значений
    /// не собирается — все четыре параметра обязательны, — поэтому эта половина зелена по
    /// построению и не доказывает ничего сверх того, что `domain-core` отказал.
    func test_k11_brokenWeights_domainCoreRefuses_soPortHasNoValues() {
        XCTAssertThrowsError(try SignalWeights.values(from: ReferenceTables.signalWeights(clientAudioOutput: 1.5)))
        XCTAssertThrowsError(try SignalWeights.values(from: ReferenceTables.signalWeights(signalTtlSeconds: 0)))
        XCTAssertThrowsError(try ReceivedValues(clientRunning: 0.4, clientAudioOutput: 1.5, microphoneInUse: 0.4,
                                                signalTtlSeconds: 60))
        XCTAssertThrowsError(try ReceivedValues(clientRunning: 0.4, clientAudioOutput: 0.8, microphoneInUse: 0.4,
                                                signalTtlSeconds: -1))
    }

    // MARK: - К6. Регулярное выражение не компилируется — отказ инициализации

    func test_k06_brokenPathRegex_failsAtBuild() {
        let broken = #"{"provider": "acme", "displayName": "Acme", "priority": 5, "urlPatterns": [{"hostSuffix": "#
            + #""acme.example", "pathRegex": "^/(?<meetingId>[0-9]+", "meetingIdQueryKey": null, "#
            + #""passcodeQueryKey": null}]}"#
        XCTAssertThrowsError(try ReferenceTables.tables(providers: ReferenceTables.providers([broken]))) {
            guard case RuleTableError.invalidPathRegex = $0 else {
                return XCTFail("ожидался отказ регулярного выражения, пришло \($0)")
            }
        }
    }

    // MARK: - К12. Файлы, как их поставляет собранный модуль

    func test_k12_shippedTables_areValid() throws {
        let providers = try DomainJSON.decode(ProvidersTable.self, from: DetectorResources.bytes(of: .providers))
        let clients = try DomainJSON.decode(ClientsTable.self, from: DetectorResources.bytes(of: .clients))
        XCTAssertEqual(providers.schemaVersion, 1)
        XCTAssertEqual(clients.schemaVersion, 1)
        for pattern in providers.providers.flatMap(\.urlPatterns) {
            XCTAssertNoThrow(try NSRegularExpression(pattern: pattern.pathRegex), pattern.pathRegex)
        }
        let conferenceKeys: Set = ["zoom", "meet", "teams", "webex", "telemost", "kontur", "salutejazz", "jitsi",
                                   "unknown"]
        let keys = Set(providers.providers.map(\.provider))
        XCTAssertFalse(keys.isEmpty)
        XCTAssertTrue(keys.isSubset(of: conferenceKeys), "ключи вне набора C-001: \(keys.subtracting(conferenceKeys))")
        XCTAssertEqual(clients.browsers, ReferenceTables.browsers)
        XCTAssertEqual(clients.clients.first { $0.provider == "meet" }?.bundleIds, [])
        for browser in clients.browsers {
            for client in clients.clients.flatMap(\.bundleIds) {
                XCTAssertFalse(bundleKeyMatches(appKey: client, entry: browser)
                               || bundleKeyMatches(appKey: browser, entry: client), "\(browser) / \(client)")
            }
        }
        XCTAssertNoThrow(try RuleTables.shipped.get())
    }

    // MARK: - К24. Подмена ресурса после инициализации ответов не меняет

    func test_k24_resourceReplacedAfterInit_answersStayTheSame() async throws {
        let values = try ReferenceTables.shippedValues()
        let detector = try MeetingDetector(clientRunning: values.clientRunning,
                                           clientAudioOutput: values.clientAudioOutput,
                                           microphoneInUse: values.microphoneInUse,
                                           signalTtlSeconds: values.signalTtlSeconds)
        let before = ResolverCorpus.answers(of: detector)
        let replacements: [(DetectorResources.Table, Data)] = [
            (.providers, Data(#"{"schemaVersion": 2, "providers": ["#.utf8)),
            (.clients, Data(#"{"schemaVersion": 1, "browsers": "#.utf8)),
            (.providers, ReferenceTables.providers([ReferenceTables.zoomEntry.replacingOccurrences(
                of: "\"priority\": 10", with: "\"priority\": 30"), ReferenceTables.meetEntry,
                ReferenceTables.acmeEntry])),
            (.clients, ReferenceTables.clients(entries: [
                #"{"provider": "zoom", "bundleIds": ["us.zoom.xos", "com.acme.desk"], "browserFallback": true}"#
            ] + ReferenceTables.clientEntries.dropFirst()))
        ]
        for (table, bytes) in replacements {
            try await withReplacedResource(table, bytes) {
                let fresh = try MeetingDetector(clientRunning: values.clientRunning,
                                                clientAudioOutput: values.clientAudioOutput,
                                                microphoneInUse: values.microphoneInUse,
                                                signalTtlSeconds: values.signalTtlSeconds)
                XCTAssertEqual(ResolverCorpus.answers(of: detector), before, "\(table): тот же объект")
                XCTAssertEqual(ResolverCorpus.answers(of: fresh), before, "\(table): новый объект того же процесса")
                let parallel = await withTaskGroup(of: ResolverCorpus.Answers.self) { group in
                    for _ in 0..<8 { group.addTask { ResolverCorpus.answers(of: detector) } }
                    return await group.reduce(into: []) { $0.append($1) }
                }
                XCTAssertEqual(parallel, Array(repeating: before, count: 8), "\(table): из параллельных задач")
            }
        }
    }

    private func withReplacedResource(_ table: DetectorResources.Table, _ bytes: Data,
                                      _ body: () async throws -> Void) async throws {
        let url = try XCTUnwrap(DetectorResources.location(of: table))
        let original = try Data(contentsOf: url)
        try bytes.write(to: url)
        do {
            try await body()
        } catch {
            try original.write(to: url)
            throw error
        }
        try original.write(to: url)
    }
}

/// Корпус запросов к резолверу и ответы на него — вход К24.
enum ResolverCorpus {

    struct Answers: Equatable {
        let joins: [JoinInfo?]
        let clientBundleIds: [[String]]
        let allKnown: [String]
        let providers: [String?]
        let browsers: [Bool]
    }

    static let texts = [
        "https://zoom.us/j/123456789?pwd=abc", "https://meet.google.com/abc-defg-hij",
        "https://acme.example/12345", "Встреча: https://us02web.zoom.us/s/987 и https://meet.google.com/xyz-abcd-efg",
        "без ссылок"
    ]
    static let keys = ["us.zoom.xos", "com.google.Chrome", "com.acme.desk", "com.microsoft.teams2"]

    static func answers(of resolver: PlatformResolver) -> Answers {
        Answers(joins: texts.map { resolver.resolve(text: $0, source: .bodyText) },
                clientBundleIds: ["zoom", "teams", "meet", "acme"].map { resolver.clientBundleIds(for: $0) },
                allKnown: resolver.allKnownClientBundleIds(),
                providers: keys.map { resolver.provider(forAppKey: $0) },
                browsers: keys.map { resolver.isBrowser(appKey: $0) })
    }
}
