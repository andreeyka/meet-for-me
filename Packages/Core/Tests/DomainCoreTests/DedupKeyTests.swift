//  MEE-352 (IR-118): тело DedupKey.make(from:) — контракт C-005 (MEE-9) v8, инварианты 1–3.
//  Инварианты 1–3 не менялись с v4 (только их формулировка и разбор в контракте).
//
//  `@testable` — ради `DomainDateGrammar.lowerBound`/`.upperBound` (внутренний тип): парные
//  векторы замечания к инварианту 3 обязаны стоять точно на границе C-001 §0.2 п. 9, не
//  рядом с ней.

import XCTest
@testable import DomainCore

final class DedupKeyTests: XCTestCase {

    // MARK: - Инвариант 2: строгий приоритет ветвей

    func test_priority_joinUrlWinsOverIcalUidAndOrganizer() throws {
        let event = try makeEvent(
            icalUid: "ical-1", organizerEmail: "a@b.com", joinUrl: URL(string: "https://zoom.us/j/123")
        )
        guard case .joinUrl = DedupKey.make(from: event) else {
            return XCTFail("ожидался .joinUrl — он первый по приоритету")
        }
    }

    func test_priority_icalUidWinsOverOrganizerWhenNoJoinUrl() throws {
        let event = try makeEvent(icalUid: "ical-1", organizerEmail: "a@b.com")
        guard case .icalUid = DedupKey.make(from: event) else {
            return XCTFail("ожидался .icalUid — второй по приоритету, joinUrl нет")
        }
    }

    /// Инвариант 2 дословно: «непустой `icalUid`» — пустая строка не считается.
    func test_priority_emptyIcalUidIsTreatedAsAbsent() throws {
        let event = try makeEvent(icalUid: "", organizerEmail: "a@b.com")
        guard case .organizerAndTime = DedupKey.make(from: event) else {
            return XCTFail("пустой icalUid не считается — ожидался .organizerAndTime")
        }
    }

    func test_priority_organizerUsedWhenNoJoinUrlOrIcalUid() throws {
        let event = try makeEvent(organizerEmail: "a@b.com")
        guard case .organizerAndTime(let email, _) = DedupKey.make(from: event) else {
            return XCTFail("ожидался .organizerAndTime")
        }
        XCTAssertEqual(email, "a@b.com")
    }

    func test_priority_nilWhenNothingIdentifies() throws {
        let event = try makeEvent()
        XCTAssertNil(DedupKey.make(from: event), "ни одна составляющая не найдена — событие не дедуплицируется")
    }

    // MARK: - Инвариант 1: детерминированность

    /// Возврат РП по MEE-352: два ОТДЕЛЬНО СОБРАННЫХ равных события, а не один и тот же
    /// `event` дважды — так утверждение действительно о значениях, а не о том, что чистая
    /// функция дважды на одном входе даёт один ответ (то само собой, свойством языка).
    func test_invariant1_deterministicForEqualEvents() throws {
        let firstEvent = try makeEvent(joinUrl: URL(string: "https://zoom.us/j/123"))
        let secondEvent = try makeEvent(joinUrl: URL(string: "https://zoom.us/j/123"))
        XCTAssertEqual(firstEvent, secondEvent, "вектор непустоты: события и впрямь равны")
        XCTAssertEqual(DedupKey.make(from: firstEvent), DedupKey.make(from: secondEvent))
    }

    // MARK: - Инвариант 2: вхождения серии не склеиваются (К27, calendar-hub)

    /// «Два разных вхождения одной серии равного ключа не получают ни при какой ветви» —
    /// тот же `joinUrl`, разный `start` — обязаны дать разные ключи.
    func test_invariant2_sameJoinUrlDifferentStartGivesDifferentKeys() throws {
        let url = URL(string: "https://zoom.us/j/123")
        let firstOccurrence = try makeEvent(start: Date(timeIntervalSince1970: 1_000_000), joinUrl: url)
        let secondOccurrence = try makeEvent(start: Date(timeIntervalSince1970: 1_100_000), joinUrl: url)
        XCTAssertNotEqual(DedupKey.make(from: firstOccurrence), DedupKey.make(from: secondOccurrence))
    }

    func test_invariant2_sameIcalUidDifferentStartGivesDifferentKeys() throws {
        let firstOccurrence = try makeEvent(start: Date(timeIntervalSince1970: 1_000_000), icalUid: "ical-1")
        let secondOccurrence = try makeEvent(start: Date(timeIntervalSince1970: 1_100_000), icalUid: "ical-1")
        XCTAssertNotEqual(DedupKey.make(from: firstOccurrence), DedupKey.make(from: secondOccurrence))
    }

    // MARK: - Инвариант 3: startEpochSeconds во ВСЕХ трёх ветвях, округление ВНИЗ до минуты

    func test_startEpochSeconds_positiveRoundsDownToContainingMinuteInAllThreeBranches() throws {
        let start = Date(timeIntervalSince1970: 1_000_090)   // на 10с позже круглой минуты
        let joinUrlEvent = try makeEvent(start: start, joinUrl: URL(string: "https://zoom.us/j/1"))
        let icalEvent = try makeEvent(start: start, icalUid: "ical-1")
        let organizerEvent = try makeEvent(start: start, organizerEmail: "a@b.com")

        for event in [joinUrlEvent, icalEvent, organizerEvent] {
            let key = try XCTUnwrap(DedupKey.make(from: event))
            XCTAssertEqual(epochSeconds(of: key), 1_000_080, "минута [1_000_080, 1_000_140) содержит 1_000_090")
        }
    }

    /// Замечание к инварианту 3: «вниз» на отрицательном `timeIntervalSince1970` — дальше от
    /// нуля, не ближе. `Int(-100.0/60)` усечением к нулю дал бы -60 (неверно); правильный
    /// ответ -120 — минута [-120, -60) содержит -100. Возврат РП по MEE-352: во всех трёх
    /// ветвях, не только `.joinUrl` — инвариант 3 не выделяет ни одну из них.
    func test_startEpochSeconds_negativeRoundsAwayFromZeroNotTowardItInAllThreeBranches() throws {
        let start = Date(timeIntervalSince1970: -100)
        let joinUrlEvent = try makeEvent(start: start, joinUrl: URL(string: "https://zoom.us/j/1"))
        let icalEvent = try makeEvent(start: start, icalUid: "ical-1")
        let organizerEvent = try makeEvent(start: start, organizerEmail: "a@b.com")

        for event in [joinUrlEvent, icalEvent, organizerEvent] {
            let key = try XCTUnwrap(DedupKey.make(from: event))
            XCTAssertEqual(epochSeconds(of: key), -120, "минута [-120, -60) содержит -100")
        }
    }

    // MARK: - Нормализация join-URL, шесть шагов «Определения» по порядку

    func test_joinUrlNormalization_lowercasesSchemeAndHost() throws {
        let event = try makeEvent(joinUrl: URL(string: "HTTPS://ZOOM.US/j/123"))
        XCTAssertEqual(try normalizedJoinURL(of: event), "https://zoom.us/j/123")
    }

    func test_joinUrlNormalization_dropsWwwPrefix() throws {
        let event = try makeEvent(joinUrl: URL(string: "https://www.zoom.us/j/123"))
        XCTAssertEqual(try normalizedJoinURL(of: event), "https://zoom.us/j/123")
    }

    func test_joinUrlNormalization_dropsDefaultHttpsPort() throws {
        let event = try makeEvent(joinUrl: URL(string: "https://zoom.us:443/j/123"))
        XCTAssertEqual(try normalizedJoinURL(of: event), "https://zoom.us/j/123", "443 — порт https по умолчанию")
    }

    func test_joinUrlNormalization_keepsNonDefaultPort() throws {
        let event = try makeEvent(joinUrl: URL(string: "https://zoom.us:8443/j/123"))
        XCTAssertEqual(try normalizedJoinURL(of: event), "https://zoom.us:8443/j/123", "не по умолчанию — остаётся")
    }

    func test_joinUrlNormalization_dropsQueryAndFragment() throws {
        let event = try makeEvent(joinUrl: URL(string: "https://zoom.us/j/123?pwd=abc#footer"))
        XCTAssertEqual(try normalizedJoinURL(of: event), "https://zoom.us/j/123")
    }

    func test_joinUrlNormalization_dropsTrailingSlashButPreservesPathCase() throws {
        let event = try makeEvent(joinUrl: URL(string: "https://teams.microsoft.com/l/meetup-join/AbC123/"))
        XCTAssertEqual(
            try normalizedJoinURL(of: event), "https://teams.microsoft.com/l/meetup-join/AbC123",
            "завершающий / отброшен, регистр пути (AbC123) сохранён"
        )
    }

    /// К15 перечня MEE-347, вход 7 (шаг 5 контракта, обратный вектор, дословно): путь без
    /// завершающего `/` не меняется — реверс шага «завершающий `/` отбрасывается, если
    /// присутствует» (тот вход всегда нёс `/` на конце). Возврат РП по MEE-369.
    func test_mee369_joinUrlNormalization_pathWithoutTrailingSlashIsUnchanged() throws {
        let event = try makeEvent(joinUrl: URL(string: "https://zoom.us/j/123"))
        XCTAssertEqual(try normalizedJoinURL(of: event), "https://zoom.us/j/123", "без / на конце — путь как есть")
    }

    /// К15 перечня MEE-347, вход 8 (шаг 5 контракта, вторая половина, дословно): регистр
    /// пути сохраняется, а не приводится к нижнему — здесь БЕЗ завершающего `/`, отдельно от
    /// шага «завершающий `/` отбрасывается» (тот вход всегда нёс `/` на конце и путь без
    /// него не проверял). Возврат РП по MEE-357, 24.09 13:00.
    func test_mee357_joinUrlNormalization_preservesPathCaseWithoutTrailingSlash() throws {
        let event = try makeEvent(joinUrl: URL(string: "https://zoom.us/J/AbC"))
        XCTAssertEqual(try normalizedJoinURL(of: event), "https://zoom.us/J/AbC", "без / на конце путь не меняется")
    }

    /// К15 перечня MEE-347, вход 9 (порядок шагов важен, дословно; номер поправлен — возврат
    /// РП по MEE-369, был по опечатке назван «вход 10»): контракт требует шаг 1
    /// (регистр схемы/хоста) СТРОГО ДО шага 2 (отбрасывание префикса `www.`) — `www.` ищется
    /// литерально, без учёта регистра. Реализация, применившая шаг 2 первым точным сравнением
    /// префикса, не поймала бы `"WWW."` вовсе и оставила бы его после понижения регистра.
    /// Возврат РП по MEE-357, 24.09 13:00.
    func test_mee357_joinUrlNormalization_lowercasesHostBeforeStrippingWwwPrefix() throws {
        let event = try makeEvent(joinUrl: URL(string: "https://WWW.zoom.us/j/123"))
        XCTAssertEqual(
            try normalizedJoinURL(of: event), "https://zoom.us/j/123",
            "шаг 1 (регистр) — раньше шага 2 (www.), иначе WWW. не будет отброшен"
        )
    }

    func test_joinUrlNormalization_allSixStepsCombined() throws {
        let event = try makeEvent(joinUrl: URL(string: "HTTPS://WWW.Zoom.US:443/j/AbC123/?pwd=xyz#top"))
        XCTAssertEqual(try normalizedJoinURL(of: event), "https://zoom.us/j/AbC123")
    }

    /// Возврат РП по MEE-352: `components.path` молча раскодирует `%3a` → `:` и `%2F` → `/` —
    /// у Teams в пути ровно такие последовательности (`19%3ameeting_…%40thread.v2`), и
    /// раскодированный путь стал бы уже другим ключом. `percentEncodedPath` — путь как он
    /// есть в исходной строке, без раскодирования.
    func test_joinUrlNormalization_preservesPercentEncodedColonAndSlashInPath() throws {
        let event = try makeEvent(joinUrl: URL(
            string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/a%2Fb"
        ))
        XCTAssertEqual(
            try normalizedJoinURL(of: event),
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/a%2Fb",
            "процентные последовательности в пути не раскодируются"
        )
    }

    /// Возврат РП по MEE-352: нормализация существует, чтобы РАЗНЫЕ строки одного и того же
    /// URL сходились в ОДИН ключ — не только «не падает на одном входе».
    func test_joinUrlNormalization_differentWritingsOfSameURLGiveSameKey() throws {
        let first = try makeEvent(joinUrl: URL(string: "HTTPS://WWW.Zoom.US:443/j/123/"))
        let second = try makeEvent(joinUrl: URL(string: "https://zoom.us/j/123"))
        XCTAssertEqual(DedupKey.make(from: first), DedupKey.make(from: second))
    }

    // MARK: - Замечание к инварианту 3: парные векторы на границах C-001 §0.2 п. 9

    func test_boundaryVector_lowerBound_joinUrlBranchHasExactEpoch() throws {
        let event = try makeEvent(
            start: DomainDateGrammar.lowerBound, joinUrl: URL(string: "https://zoom.us/j/1")
        )
        guard case .joinUrl(_, let epoch) = DedupKey.make(from: event) else {
            return XCTFail("ожидался .joinUrl на нижней границе диапазона — без крушения")
        }
        XCTAssertEqual(epoch, Self.lowerBoundEpochSeconds)
    }

    func test_boundaryVector_lowerBound_icalUidBranchHasExactEpoch() throws {
        let event = try makeEvent(start: DomainDateGrammar.lowerBound, icalUid: "ical-1")
        guard case .icalUid(_, let epoch) = DedupKey.make(from: event) else {
            return XCTFail("ожидался .icalUid на нижней границе диапазона — без крушения")
        }
        XCTAssertEqual(epoch, Self.lowerBoundEpochSeconds)
    }

    func test_boundaryVector_lowerBound_organizerBranchHasExactEpoch() throws {
        let event = try makeEvent(start: DomainDateGrammar.lowerBound, organizerEmail: "a@b.com")
        guard case .organizerAndTime(_, let epoch) = DedupKey.make(from: event) else {
            return XCTFail("ожидался .organizerAndTime на нижней границе диапазона — без крушения")
        }
        XCTAssertEqual(epoch, Self.lowerBoundEpochSeconds)
    }

    func test_boundaryVector_upperBound_joinUrlBranchHasExactEpoch() throws {
        let event = try makeEvent(
            start: DomainDateGrammar.upperBound, joinUrl: URL(string: "https://zoom.us/j/1")
        )
        guard case .joinUrl(_, let epoch) = DedupKey.make(from: event) else {
            return XCTFail("ожидался .joinUrl на верхней границе диапазона — без крушения")
        }
        XCTAssertEqual(epoch, Self.upperBoundEpochSeconds)
    }

    func test_boundaryVector_upperBound_icalUidBranchHasExactEpoch() throws {
        let event = try makeEvent(start: DomainDateGrammar.upperBound, icalUid: "ical-1")
        guard case .icalUid(_, let epoch) = DedupKey.make(from: event) else {
            return XCTFail("ожидался .icalUid на верхней границе диапазона — без крушения")
        }
        XCTAssertEqual(epoch, Self.upperBoundEpochSeconds)
    }

    func test_boundaryVector_upperBound_organizerBranchHasExactEpoch() throws {
        let event = try makeEvent(start: DomainDateGrammar.upperBound, organizerEmail: "a@b.com")
        guard case .organizerAndTime(_, let epoch) = DedupKey.make(from: event) else {
            return XCTFail("ожидался .organizerAndTime на верхней границе диапазона — без крушения")
        }
        XCTAssertEqual(epoch, Self.upperBoundEpochSeconds)
    }

    /// Отрицательный вектор замечания: `start` вне диапазона не доходит до `make` вовсе —
    /// `MeetingEvent.init` отказывает раньше (C-001 §0.2 п. 9, инвариант 0), поэтому вторая
    /// проверка диапазона внутри `make` не нужна и не написана.
    func test_boundaryVector_beforeLowerBoundIsRejectedAtConstructionNotInMake() throws {
        assertInvariant(
            try makeEvent(start: DomainDateGrammar.lowerBound.addingTimeInterval(-1)),
            contract: "C-001", type: "MeetingEvent", invariant: 0, path: "start"
        )
    }

    func test_boundaryVector_afterUpperBoundIsRejectedAtConstructionNotInMake() throws {
        assertInvariant(
            try makeEvent(start: DomainDateGrammar.upperBound.addingTimeInterval(1)),
            contract: "C-001", type: "MeetingEvent", invariant: 0, path: "start"
        )
    }

    // MARK: - Оснастка

    /// Возврат РП по MEE-352: `-62135596800` — `0001-01-01T00:00:00.000Z`, уже кратно 60,
    /// округление вниз не сдвигает. Значение проверено независимо от кода `startEpochSeconds`.
    private static let lowerBoundEpochSeconds = -62_135_596_800
    /// `253402300740` — минута `[253402300740, 253402300800)`, `9999-12-31T23:59:59.999Z`
    /// (`253402300799.999`) лежит внутри неё; `253402300800` — уже `10000-01-01T00:00:00Z`.
    private static let upperBoundEpochSeconds = 253_402_300_740

    private func makeEvent(
        start: Date = Date(timeIntervalSince1970: 1_000_090),
        icalUid: String? = nil,
        organizerEmail: String? = nil,
        joinUrl: URL? = nil
    ) throws -> MeetingEvent {
        let organizer = try organizerEmail.map { try MeetingEvent.Person(name: nil, email: $0) }
        let conference = try joinUrl.map {
            try MeetingEvent.Conference(provider: "zoom", joinUrl: $0, meetingId: nil, passcode: nil)
        }
        return try MeetingEvent(
            id: try makeUUID("22222222-2222-4222-8222-222222222222"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: icalUid, title: "T",
            start: start, end: start, timeZone: "UTC", isAllDay: false, isCancelled: false,
            organizer: organizer, attendees: [], location: nil, bodyText: nil,
            conference: conference, lastModified: start
        )
    }

    private func epochSeconds(of key: DedupKey) -> Int {
        switch key {
        case .joinUrl(_, let seconds), .icalUid(_, let seconds), .organizerAndTime(_, let seconds):
            return seconds
        }
    }

    private func normalizedJoinURL(
        of event: MeetingEvent, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let key = try XCTUnwrap(DedupKey.make(from: event), file: file, line: line)
        guard case .joinUrl(let normalized, _) = key else {
            XCTFail("ожидался .joinUrl", file: file, line: line)
            return ""
        }
        return normalized
    }
}
