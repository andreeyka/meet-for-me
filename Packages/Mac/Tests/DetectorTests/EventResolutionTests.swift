//  Разбор события календаря: `PlatformResolver.resolve(event:)`, инварианты 3, 4 и 5 C-009.
//  Критерии К13, К15, К16, К17, К18, К23, К74 перечня MEE-75; способ — Ф плана MEE-126.
//
//  Место, где критерий расходится с исполнимым, осталось одно. Названо оно отчётом MEE-220
//  и здесь не чинится — чужая зона (перечень аналитика):
//
//  **Все три входа К18 неконструируемы.** Критерий подаёт `conference` с `http`-URL, с
//  относительным путём и с текстом, не являющимся URL, и ждёт `nil`. Ни одно из трёх не
//  доходит до резолвера: тот же признак стоит инвариантом 5 C-001 и отвергает значение
//  при создании `MeetingEvent.Conference`. Проверено то, что проверяемо, — что признак
//  ослаблению не подлежит; ослабнет он — тест покраснеет, и К18 придётся переписать.
//
//  Второе место — «третий вызов К13 исполнить нечем» — закрыто не здесь и не нами: издание
//  C-009 v8 (IR-097) сняло стадию `eventUrl` из инварианта 3 и случай `.eventUrl` из
//  `JoinInfo.Source`, после чего К13 переписан на три вызова из трёх. Требования без входа
//  больше нет, и подменять его похожим по-прежнему нечем и незачем.

import DomainCore
import Foundation
import XCTest
@testable import Detector

final class EventResolutionTests: XCTestCase {

    // MARK: - К13. Порядок полей события

    /// Три вызова, три ответа — по числу полей, из которых контракт берёт ссылку.
    ///
    /// Вход ВТОРОГО вызова разведён с входом К74 намеренно: правило, совпавшее в `location`,
    /// по §3 проверяется РАНЬШЕ правила, совпавшего в `bodyText`, — то есть порядок полей и
    /// порядок `priority` здесь не спорят. Соотношения `priority` вход К13 не требует и
    /// подавать его не обязан (план MEE-126, `АЖ.3`); спорящий вход — предмет К74, и там он
    /// утверждается, а не наследуется из таблицы. Пока эти два входа совпадали побайтово,
    /// зелёные К13 и К74 вместе не доказывали, что реализация держит два разных требования,
    /// а лишь что она проходит оба на одном входе (план MEE-126, `АЖ.5`).
    func test_k13_firstMatchingFieldWinsInContractOrder() throws {
        let resolver = try threeProviderDetector()

        let whole = try event(conference: try conference(Self.zoomLink),
                              location: "Где: \(Self.acmeLink)",
                              bodyText: "Резерв: \(Self.meetLink)")
        let fromConference = try XCTUnwrap(resolver.resolve(event: whole))
        XCTAssertEqual(fromConference.source, .conferenceField)
        XCTAssertEqual(fromConference.provider, "zoom")

        let withoutConference = try event(location: "Где: \(Self.acmeLink)",
                                          bodyText: "Резерв: \(Self.meetLink)")
        let fromLocation = try XCTUnwrap(resolver.resolve(event: withoutConference))
        XCTAssertEqual(fromLocation.source, .location)
        XCTAssertEqual(fromLocation.provider, "acme")

        let bodyOnly = try event(bodyText: "Резерв: \(Self.meetLink)")
        let fromBody = try XCTUnwrap(resolver.resolve(event: bodyOnly))
        XCTAssertEqual(fromBody.source, .bodyText)
        XCTAssertEqual(fromBody.provider, "meet")
    }

    // MARK: - К74. Порядок полей старше приоритета правила

    /// Вторая половина инварианта 3, отдельным утверждением: побеждает поле, а не правило.
    /// `location` несёт провайдера с бо́льшим `priority`, чем `bodyText`, — по §3 его правило
    /// проверялось бы позже, — и всё равно выигрывает то, что стоит раньше в порядке полей.
    /// Без этого вектора разбор, склеивающий поля в один текст и отдающий его
    /// `resolve(text:source:)`, проходит К13 целиком.
    func test_k74_fieldOrderBeatsRulePriority() throws {
        // Соотношение `priority` — часть входа К74, а не свойство оснастки, и утверждается
        // здесь же (план MEE-126, `АЖ.4`): правка таблицы, сделавшая неравенство ложным,
        // обязана покраснеть, а не превратить этот вход во вход второго вызова К13 молча.
        let table = try DomainJSON.decode(ProvidersTable.self, from: Self.threeProviders)
        let priority = Dictionary(uniqueKeysWithValues: table.providers.map { ($0.provider, $0.priority) })
        let inLocation = try XCTUnwrap(priority["meet"])
        let inBodyText = try XCTUnwrap(priority["acme"])
        XCTAssertGreaterThan(inLocation, inBodyText,
                             "правило `location` обязано проверяться позже правила `bodyText`")

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

    /// Три провайдера: по одному на каждое поле события, дающее вход. Байты вынесены в
    /// свойство, потому что К74 утверждает `priority` по тем же самым байтам, из которых
    /// собран резолвер, — иначе утверждение относилось бы к другой таблице.
    static let threeProviders = ReferenceTables.providers([ReferenceTables.zoomEntry,
                                                          ReferenceTables.meetEntry,
                                                          ReferenceTables.acmeEntry])

    private func threeProviderDetector() throws -> MeetingDetector {
        try Harness(tables: ReferenceTables.tables(providers: Self.threeProviders)).detector
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
