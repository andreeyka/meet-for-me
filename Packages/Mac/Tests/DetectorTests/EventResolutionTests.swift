//  Разбор события календаря: `PlatformResolver.resolve(event:)`, инварианты 3, 4 и 5 C-009.
//  Критерии К13, К15, К16, К17, К18, К23 перечня MEE-75; способ — Ф плана MEE-126.
//
//  Два места, где критерий разошёлся с исполнимым. Оба названы отчётом MEE-220 и здесь не
//  чинятся — чужая зона (перечень аналитика, контракт архитектора):
//
//  1. **Третий вызов К13 — «без `conference` и `location` → `.eventUrl`» — исполнить нечем.**
//     Порядок инварианта 3 называет четыре поля, а `MeetingEvent` (C-001 v11) объявляет три,
//     из которых берут ссылку: `conference`, `location`, `bodyText`. Поля URL события в DTO
//     нет ни под каким именем, вхождений `eventUrl` в тексте C-001 — ноль. Стадия остаётся
//     без входа, и `JoinInfo.Source.eventUrl` разбором события не порождается никогда.
//     Здесь проверены три вызова из четырёх; четвёртый не подменяется похожим.
//  2. **Все три входа К18 неконструируемы.** Критерий подаёт `conference` с `http`-URL, с
//     относительным путём и с текстом, не являющимся URL, и ждёт `nil`. Ни одно из трёх не
//     доходит до резолвера: тот же признак стоит инвариантом 5 C-001 и отвергает значение
//     при создании `MeetingEvent.Conference`. Проверено то, что проверяемо, — что признак
//     ослаблению не подлежит; ослабнет он — тест покраснеет, и К18 придётся переписать.

import DomainCore
import Foundation
import XCTest
@testable import Detector

final class EventResolutionTests: XCTestCase {

    // MARK: - К13. Порядок полей события

    func test_k13_firstMatchingFieldWinsInContractOrder() throws {
        let resolver = try threeProviderDetector()

        let whole = try event(conference: try conference(Self.zoomLink),
                              location: "Где: \(Self.meetLink)",
                              bodyText: "Резерв: \(Self.acmeLink)")
        let fromConference = try XCTUnwrap(resolver.resolve(event: whole))
        XCTAssertEqual(fromConference.source, .conferenceField)
        XCTAssertEqual(fromConference.provider, "zoom")

        let withoutConference = try event(location: "Где: \(Self.meetLink)",
                                          bodyText: "Резерв: \(Self.acmeLink)")
        let fromLocation = try XCTUnwrap(resolver.resolve(event: withoutConference))
        XCTAssertEqual(fromLocation.source, .location)
        XCTAssertEqual(fromLocation.provider, "meet")

        let bodyOnly = try event(bodyText: "Резерв: \(Self.acmeLink)")
        let fromBody = try XCTUnwrap(resolver.resolve(event: bodyOnly))
        XCTAssertEqual(fromBody.source, .bodyText)
        XCTAssertEqual(fromBody.provider, "acme")
    }

    /// Вторая половина инварианта 3, отдельным утверждением: побеждает поле, а не правило.
    /// `location` несёт провайдера с бо́льшим `priority`, чем `bodyText`, и всё равно выигрывает
    /// то, что стоит раньше в порядке полей. Без этого вектора разбор, склеивающий поля в один
    /// текст и отдающий его `resolve(text:source:)`, проходит К13 целиком.
    func test_k13_fieldOrderBeatsRulePriority() throws {
        let resolver = try threeProviderDetector()
        let mixed = try event(location: "Где: \(Self.meetLink)", bodyText: "Резерв: \(Self.acmeLink)")
        let answer = try XCTUnwrap(resolver.resolve(event: mixed))
        XCTAssertEqual(answer.source, .location, "порядок полей старше приоритета правила")
        XCTAssertEqual(answer.provider, "meet")
    }

    // MARK: - К15. Ни одно поле не совпало и `conference` нет

    func test_k15_eventWithoutConferenceAndWithoutMatches_isNil() throws {
        let resolver = try threeProviderDetector()
        let nothing = try event(location: "Переговорная 3",
                                bodyText: "Повестка: планы на неделю. https://example.com/page")
        XCTAssertNil(resolver.resolve(event: nothing))
    }

    // MARK: - К16. Единственное исключение инварианта 4

    func test_k16_unmatchedConferenceUrl_yieldsUnknownWithAllSixFields() throws {
        let resolver = try threeProviderDetector()
        let url = try XCTUnwrap(URL(string: "https://vc.example.org/room/42"))
        let sample = try event(conference: try MeetingEvent.Conference(provider: "unknown", joinUrl: url,
                                                                       meetingId: nil, passcode: nil),
                               location: "Переговорная 3",
                               bodyText: "Ссылок нет.")
        let info = try XCTUnwrap(resolver.resolve(event: sample))
        XCTAssertEqual(info.provider, "unknown")
        XCTAssertEqual(info.source, .conferenceField)
        XCTAssertEqual(info.joinUrl, url)
        XCTAssertNil(info.meetingId)
        XCTAssertNil(info.passcode)
        XCTAssertEqual(info.clientBundleIds, [])
    }

    /// Исключение обусловлено тем, что не совпало ни одно правило **ни в одном** поле. Событие,
    /// у которого `conference` не совпал, а `bodyText` совпал, отдаёт совпадение, а не `unknown`.
    func test_k16_exceptionYieldsOnlyWhenNoFieldMatched() throws {
        let resolver = try threeProviderDetector()
        let url = try XCTUnwrap(URL(string: "https://vc.example.org/room/42"))
        let sample = try event(conference: try MeetingEvent.Conference(provider: "unknown", joinUrl: url,
                                                                       meetingId: nil, passcode: nil),
                               bodyText: "Резерв: \(Self.acmeLink)")
        let info = try XCTUnwrap(resolver.resolve(event: sample))
        XCTAssertEqual(info.provider, "acme")
        XCTAssertEqual(info.source, .bodyText)
    }

    // MARK: - К17. Вторая половина инварианта 4

    func test_k17_unmatchedLinkInBodyTextOnly_isNilAndNeverUnknown() throws {
        let resolver = try threeProviderDetector()
        let answer = resolver.resolve(event: try event(bodyText: "Ссылка: https://example.com/page"))
        XCTAssertNil(answer)
        XCTAssertNotEqual(answer?.provider, "unknown", "произвольная ссылка из bodyText JoinInfo не порождает")
    }

    /// То же для `location`: исключение принадлежит структурному полю, а не всякому полю.
    func test_k17_unmatchedLinkInLocationOnly_isNil() throws {
        let resolver = try threeProviderDetector()
        XCTAssertNil(resolver.resolve(event: try event(location: "https://example.com/page")))
    }

    // MARK: - К18. Исключение требует абсолютного `https` и ослаблению не подлежит

    func test_k18_conferenceExceptionIsNotWeakenedBelowAbsoluteHttps() throws {
        for raw in ["http://example.com/x", "/j/123", "meeting-room-7"] {
            let url = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertThrowsError(try MeetingEvent.Conference(provider: "unknown", joinUrl: url,
                                                             meetingId: nil, passcode: nil), raw) { error in
                guard let failure = error as? DomainValidationError else {
                    XCTFail("ожидался DomainValidationError, получено \(error)")
                    return
                }
                XCTAssertEqual(failure.contract, "C-001", raw)
                XCTAssertEqual(failure.type, "MeetingEvent.Conference", raw)
                XCTAssertEqual(failure.invariant, 5, raw)
                XCTAssertEqual(failure.path, "joinUrl", raw)
            }
        }
    }

    /// Половина К18, которую резолвер отвечает сам: `https`-URL, не совпавший с правилом,
    /// исключение даёт, а тот же путь без схемы до исключения не доходит — он и в поле не лёг.
    func test_k18_onlyAbsoluteHttpsConferenceReachesTheException() throws {
        let resolver = try threeProviderDetector()
        let url = try XCTUnwrap(URL(string: "https://example.com/j/123"))
        let sample = try event(conference: try MeetingEvent.Conference(provider: "unknown", joinUrl: url,
                                                                       meetingId: nil, passcode: nil))
        XCTAssertEqual(try XCTUnwrap(resolver.resolve(event: sample)).provider, "unknown")
    }

    // MARK: - К23. Инвариант 2: детерминированность под параллельными вызовами

    func test_k23_thousandParallelCalls_giveOneAndTheSameAnswer() async throws {
        let resolver = try threeProviderDetector()
        let sample = try event(conference: try conference(Self.zoomLink),
                               location: "Где: \(Self.meetLink)",
                               bodyText: "Резерв: \(Self.acmeLink)")
        let expected = try XCTUnwrap(resolver.resolve(event: sample))
        let answers = await withTaskGroup(of: [JoinInfo?].self) { group in
            for _ in 0..<8 {
                group.addTask { (0..<125).map { _ in resolver.resolve(event: sample) } }
            }
            return await group.reduce(into: [JoinInfo?]()) { $0.append(contentsOf: $1) }
        }
        XCTAssertEqual(answers.count, 1000)
        XCTAssertEqual(answers.compactMap { $0 }.count, 1000, "ни один вызов не ответил nil")
        XCTAssertEqual(Set(answers.compactMap { $0 }.map(\.joinUrl)), [expected.joinUrl])
        XCTAssertTrue(answers.allSatisfy { $0 == expected }, "ответы разошлись между задачами")
    }

    // MARK: - Оснастка

    static let zoomLink = "https://zoom.us/j/1234567890"
    static let meetLink = "https://meet.google.com/abc-defg-hij"
    static let acmeLink = "https://acme.example/12345"

    /// Три провайдера: по одному на каждое поле события, дающее вход.
    private func threeProviderDetector() throws -> MeetingDetector {
        let providers = ReferenceTables.providers([ReferenceTables.zoomEntry,
                                                   ReferenceTables.meetEntry,
                                                   ReferenceTables.acmeEntry])
        return try Harness(tables: ReferenceTables.tables(providers: providers)).detector
    }

    private func conference(_ link: String, provider: String = "zoom") throws -> MeetingEvent.Conference {
        try MeetingEvent.Conference(provider: provider,
                                    joinUrl: try XCTUnwrap(URL(string: link)),
                                    meetingId: nil,
                                    passcode: nil)
    }

    /// Событие, отличающееся от соседнего только теми полями, из которых берут ссылку.
    private func event(conference: MeetingEvent.Conference? = nil,
                       location: String? = nil,
                       bodyText: String? = nil) throws -> MeetingEvent {
        try MeetingEvent(
            id: try XCTUnwrap(UUID(uuidString: "5A1E0153-0000-4000-8000-000000000001")),
            sourceConnectorId: "eventkit",
            externalId: "evt-153",
            icalUid: nil,
            title: "Разбор события",
            start: Date(timeIntervalSince1970: 1_789_119_000),
            end: Date(timeIntervalSince1970: 1_789_120_800),
            timeZone: "Europe/Moscow",
            isAllDay: false,
            isCancelled: false,
            organizer: nil,
            attendees: [],
            location: location,
            bodyText: bodyText,
            conference: conference,
            lastModified: Date(timeIntervalSince1970: 1_789_041_600)
        )
    }
}
