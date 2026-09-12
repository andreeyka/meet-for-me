//  П. 147: четыре типа раздела «Определение» C-009 переживают `DomainJSON` туда-обратно
//  и равны себе. Код влит MEE-86, тестов на него не было ни одного.
//
//  Равенство утверждается по каждому полю отдельно, а не только `==` целиком: `Equatable`
//  у всех четырёх синтезирован и сравнивает те же поля, что кодируются, — тест на одном `==`
//  зелен на реализации, потерявшей поле в обе стороны сразу.
//
//  Q31: все `Date` строятся на границе миллисекунды через `date(milliseconds:)`, а не через
//  `Date()`. `DomainDateGrammar.string(from:)` округляет до миллисекунд, и значение с
//  субмиллисекундной точностью круга по `==` не переживает — на `Date()` пункт был бы красен
//  на верной реализации, и красен плавающе.
//
//  Q32: пара «все необязательные `nil`» / «все заполнены» стоит в одном тесте. Порознь первая
//  зелена на реализации, теряющей необязательные поля, вторая — на подставляющей умолчания.

import XCTest
import DomainCore

final class C009RoundTripTests: XCTestCase {

    func test_p147_c009RoundTrip_audioProcess_nilAndFilled() throws {
        let empty = AudioProcess(pid: 7, bundleId: nil, responsibleBundleId: nil,
                                 executableName: "bare", isRunningOutput: false,
                                 isRunningInput: false, observedAt: moment)
        let filled = AudioProcess(pid: 900, bundleId: "com.google.Chrome.helper",
                                  responsibleBundleId: "com.google.Chrome",
                                  executableName: "Google Chrome Helper", isRunningOutput: true,
                                  isRunningInput: true, observedAt: moment)
        for value in [empty, filled] {
            let back = try roundTrip(value)
            XCTAssertEqual(back, value)
            XCTAssertEqual(back.pid, value.pid)
            XCTAssertEqual(back.bundleId, value.bundleId)
            XCTAssertEqual(back.responsibleBundleId, value.responsibleBundleId)
            XCTAssertEqual(back.executableName, value.executableName)
            XCTAssertEqual(back.isRunningOutput, value.isRunningOutput)
            XCTAssertEqual(back.isRunningInput, value.isRunningInput)
            XCTAssertEqual(back.observedAt, value.observedAt)
        }
    }

    func test_p147_c009RoundTrip_processGroup_emptyAndFilledPids() throws {
        let values = [
            ProcessGroup(appKey: "com.google.Chrome", pids: [], observedAt: moment),
            ProcessGroup(appKey: "com.google.Chrome", pids: [120, 900], observedAt: moment)
        ]
        for value in values {
            let back = try roundTrip(value)
            XCTAssertEqual(back, value)
            XCTAssertEqual(back.appKey, value.appKey)
            XCTAssertEqual(back.pids, value.pids)
            XCTAssertEqual(back.observedAt, value.observedAt)
        }
    }

    func test_p147_c009RoundTrip_meetingSignal_nilAndNestedGroup() throws {
        let bare = MeetingSignal(kind: .calendarWindow, weight: 0.2, pid: nil, bundleId: nil,
                                 group: nil, provider: nil, meetingId: nil, observedAt: moment)
        let nested = MeetingSignal(
            kind: .clientAudioOutput, weight: 0.8, pid: 900,
            bundleId: "com.google.Chrome.helper",
            group: ProcessGroup(appKey: "com.google.Chrome", pids: [120, 900], observedAt: moment),
            provider: "zoom",
            meetingId: try makeUUID("3f2504e0-4f89-41d3-9a0c-0305e82c3301"),
            observedAt: moment)
        for value in [bare, nested] {
            let back = try roundTrip(value)
            XCTAssertEqual(back, value)
            XCTAssertEqual(back.kind, value.kind)
            XCTAssertEqual(back.weight, value.weight)
            XCTAssertEqual(back.pid, value.pid)
            XCTAssertEqual(back.bundleId, value.bundleId)
            XCTAssertEqual(back.group, value.group)
            XCTAssertEqual(back.group?.pids, value.group?.pids)
            XCTAssertEqual(back.provider, value.provider)
            XCTAssertEqual(back.meetingId, value.meetingId)
            XCTAssertEqual(back.observedAt, value.observedAt)
        }
    }

    func test_p147_c009RoundTrip_joinInfo_emptyAndFilledClientBundleIds() throws {
        let bare = JoinInfo(provider: "meet", joinUrl: try makeURL("https://meet.google.com/abc"),
                            meetingId: nil, passcode: nil, clientBundleIds: [],
                            source: .conferenceField)
        let filled = JoinInfo(provider: "zoom", joinUrl: try makeURL("https://zoom.us/j/123"),
                              meetingId: "123", passcode: "pwd",
                              clientBundleIds: ["us.zoom.xos"], source: .bodyText)
        for value in [bare, filled] {
            let back = try roundTrip(value)
            XCTAssertEqual(back, value)
            XCTAssertEqual(back.provider, value.provider)
            XCTAssertEqual(back.joinUrl, value.joinUrl)
            XCTAssertEqual(back.meetingId, value.meetingId)
            XCTAssertEqual(back.passcode, value.passcode)
            XCTAssertEqual(back.clientBundleIds, value.clientBundleIds)
            XCTAssertEqual(back.source, value.source)
        }
    }

    /// Все четыре объявлены `Codable, Equatable, Sendable` — иначе круг не собрался бы вовсе.
    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try DomainJSON.decode(Value.self, from: DomainJSON.encode(value))
    }

    /// Отметка на границе миллисекунды.
    private var moment: Date { date(milliseconds: 1_757_000_000_123) }
}
