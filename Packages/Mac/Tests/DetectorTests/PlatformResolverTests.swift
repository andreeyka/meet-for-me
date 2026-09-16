//  Критерии блоков B и C перечня MEE-75: разбор ссылок и правило §4.1 на стороне адаптера.
//  К14, К19, К20, К21, К22, К27, К28, К31.
//
//  К13, К15—К18 и К23 проверяются только через `resolve(event:)` и живут отдельным файлом —
//  `EventResolutionTests.swift` (MEE-220).

import DomainCore
import Foundation
import XCTest
@testable import Detector

final class PlatformResolverTests: XCTestCase {

    private func detector(providers: Data = ReferenceTables.providers()) throws -> MeetingDetector {
        try Harness(tables: ReferenceTables.tables(providers: providers)).detector
    }

    // MARK: - К14. Приоритет правил, при равенстве — порядок файла

    func test_k14_lowerPriorityWins_thenFileOrder() throws {
        func entry(_ name: String, _ priority: Int) -> String {
            #"{"provider": "\#(name)", "displayName": "\#(name)", "priority": \#(priority), "urlPatterns": [{"#
                + #""hostSuffix": "\#(name).example", "pathRegex": "^/(?<meetingId>[0-9]+)", "#
                + #""meetingIdQueryKey": null, "passcodeQueryKey": null}]}"#
        }
        let text = "сначала https://beta.example/2, потом https://alpha.example/1"
        let byPriority = try detector(providers: ReferenceTables.providers([entry("beta", 20), entry("alpha", 10)]))
        XCTAssertEqual(byPriority.resolve(text: text, source: .location)?.provider, "alpha")
        let byOrder = try detector(providers: ReferenceTables.providers([entry("beta", 10), entry("alpha", 10)]))
        XCTAssertEqual(byOrder.resolve(text: text, source: .location)?.provider, "beta")
    }

    // MARK: - К19, К20. Корпус совпадающих ссылок

    static let zoomLinks = (0..<15).map { index -> String in
        let path = ["j", "s", "w"][index % 3]
        let host = index % 2 == 0 ? "zoom.us" : "us0\(index % 9)web.zoom.us"
        return "https://\(host)/\(path)/\(80_000_000 + index)" + (index % 4 == 0 ? "?pwd=Secret\(index)" : "")
    }

    static let meetLinks = (0..<15).map { index -> String in
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let code = (0..<10).map { String(letters[($0 * 7 + index) % 26]) }
        return "https://meet.google.com/\(code[0..<3].joined())-\(code[3..<7].joined())-\(code[7..<10].joined())"
    }

    func test_k19_everyResolvedJoinUrl_isAbsoluteHttps() throws {
        let resolver = try detector()
        let corpus = Self.zoomLinks + Self.meetLinks
        XCTAssertEqual(corpus.count, 30)
        for link in corpus {
            let info = try XCTUnwrap(resolver.resolve(text: "Ссылка: \(link).", source: .bodyText), link)
            XCTAssertEqual(info.joinUrl.scheme, "https", link)
            XCTAssertNotNil(info.joinUrl.host, link)
            XCTAssertNotNil(URL(string: info.joinUrl.absoluteString)?.scheme, link)
        }
    }

    func test_k20_provider_belongsToLoadedTableKeysOrUnknown() throws {
        let standard = try detector()
        let withAcme = try detector(providers: ReferenceTables.providers(
            [ReferenceTables.zoomEntry, ReferenceTables.meetEntry, ReferenceTables.acmeEntry]))
        let corpus = Self.zoomLinks + Self.meetLinks + ["https://acme.example/42"]
        for (resolver, keys) in [(standard, Set(["zoom", "meet", "unknown"])),
                                 (withAcme, Set(["zoom", "meet", "acme", "unknown"]))] {
            for link in corpus {
                if let provider = resolver.resolve(text: link, source: .eventUrl)?.provider {
                    XCTAssertTrue(keys.contains(provider), "\(provider) вне ключей загруженной таблицы")
                }
            }
        }
        XCTAssertNil(standard.resolve(text: "https://acme.example/42", source: .eventUrl))
        XCTAssertEqual(withAcme.resolve(text: "https://acme.example/42", source: .eventUrl)?.provider, "acme")
    }

    /// §3 без номера критерия: хост равен `hostSuffix` или кончается на `"." + hostSuffix` —
    /// граница по точке, а не по вхождению подстроки. `http` и относительная ссылка не разбираются.
    func test_section3_hostSuffix_matchesOnDotBoundaryOnly_httpsOnly() throws {
        let resolver = try detector()
        XCTAssertEqual(resolver.resolve(text: "https://ZOOM.us/j/1", source: .location)?.provider, "zoom")
        XCTAssertEqual(resolver.resolve(text: "https://a.b.zoom.us/j/1", source: .location)?.provider, "zoom")
        XCTAssertNil(resolver.resolve(text: "https://evilzoom.us/j/1", source: .location))
        XCTAssertNil(resolver.resolve(text: "https://zoom.us.evil.example/j/1", source: .location))
        XCTAssertNil(resolver.resolve(text: "http://zoom.us/j/1", source: .conferenceField))
        XCTAssertNil(resolver.resolve(text: "/j/123", source: .conferenceField))
        XCTAssertNil(resolver.resolve(text: "https://example.com/x", source: .conferenceField))
        let withPasscode = resolver.resolve(text: "https://zoom.us/j/77?pwd=abc", source: .eventUrl)
        XCTAssertEqual(withPasscode?.meetingId, "77")
        XCTAssertEqual(withPasscode?.passcode, "abc")
        XCTAssertEqual(withPasscode?.clientBundleIds, ["us.zoom.xos"])
    }

    // MARK: - К21, К22. Клиенты провайдеров

    func test_k21_unknownProvider_hasNoClients() throws {
        let resolver = try detector()
        XCTAssertEqual(resolver.clientBundleIds(for: "нет-такого-провайдера"), [])
        XCTAssertEqual(resolver.clientBundleIds(for: ""), [])
    }

    func test_k22_allKnownClients_isUnionWithoutBrowsers() throws {
        let resolver = try detector()
        let tables = try ReferenceTables.tables()
        XCTAssertEqual(Set(resolver.allKnownClientBundleIds()), Set(tables.clients.flatMap(\.bundleIds)))
        for browser in tables.browsers {
            XCTAssertFalse(resolver.allKnownClientBundleIds().contains(browser), browser)
        }
        XCTAssertFalse(resolver.allKnownClientBundleIds().contains("com.google.Chrome"))
        XCTAssertFalse(resolver.allKnownClientBundleIds().contains("com.apple.Safari"))
    }

    // MARK: - К27, К28. Инвариант 9 на загруженной таблице

    static let fiveCases: [RawProcessRecord] = [
        Record.make(501, bundle: "com.google.Chrome.helper", responsible: 500),
        Record.make(502, bundle: "com.google.Chrome.helper"),
        Record.make(601, bundle: "com.apple.WebKit.GPU", responsible: 600),
        Record.make(602, bundle: "com.apple.WebKit.GPU"),
        Record.make(701, bundle: "com.apple.WebKit.GPU", responsible: 700)
    ]

    static let fiveCasesBundles: [Int32: String] = [
        500: "com.google.Chrome", 600: "com.apple.Safari", 700: "com.example.OtherWebKitApp"
    ]

    func test_k27_isBrowser_onFiveMeasuredCases() throws {
        let resolver = try detector()
        let snapshot = SnapshotBuilder.audioProcesses(
            from: RawSnapshot(records: Self.fiveCases, bundleIdsByPid: Self.fiveCasesBundles), observedAt: Date())
        let answers = snapshot.map { process in process.appKey.map { resolver.isBrowser(appKey: $0) } }
        XCTAssertEqual(answers, [true, true, true, false, false])
    }

    func test_k28_isBrowser_isFalseOffTheRule() throws {
        let resolver = try detector()
        for key in ["com.google.ChromeX", "com.google", "us.zoom.xos", ""] {
            XCTAssertFalse(resolver.isBrowser(appKey: key), key)
        }
    }

    // MARK: - К31. Провайдер по ключу приложения

    func test_k31_providerForAppKey() throws {
        let resolver = try detector()
        XCTAssertEqual(resolver.provider(forAppKey: "us.zoom.xos"), "zoom")
        XCTAssertEqual(resolver.provider(forAppKey: "us.zoom.xos.helper"), "zoom")
        XCTAssertNil(resolver.provider(forAppKey: "com.google.Chrome"))
        XCTAssertNil(resolver.provider(forAppKey: "com.apple.WebKit.GPU"))
    }
}
