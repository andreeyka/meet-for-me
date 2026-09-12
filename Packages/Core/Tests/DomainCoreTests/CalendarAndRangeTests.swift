//  Пп. 124, 125, 126: фундамент инварианта 7, повторяющийся ключ и диапазон `Date`.
//
//  Утверждения п. 124 записаны свойствами, а не литеральными мгновениями UTC, намеренно:
//  проверить нужно ровно то, на что опирается инвариант 7, — что `startOfDay` даёт первое
//  существующее мгновение суток, а не полночь.

import XCTest
import DomainCore

final class CalendarAndRangeTests: XCTestCase {

    private let springDates = [DSTDate(zone: "Asia/Beirut", year: 2026, month: 3, day: 29),
                               DSTDate(zone: "America/Havana", year: 2026, month: 3, day: 8),
                               DSTDate(zone: "America/Santiago", year: 2026, month: 9, day: 6)]
    private let autumnDate = DSTDate(zone: "America/Havana", year: 2026, month: 11, day: 1)

    func test_p124_startOfDayIsAFixedPoint() throws {
        for entry in springDates + [autumnDate] {
            let calendar = try gregorian(entry.zone)
            let start = calendar.startOfDay(for: try noon(entry, calendar: calendar))
            XCTAssertEqual(calendar.startOfDay(for: start), start, entry.zone)
        }
    }

    func test_p124_springDatesHaveNoMidnight() throws {
        for entry in springDates {
            let calendar = try gregorian(entry.zone)
            let start = calendar.startOfDay(for: try noon(entry, calendar: calendar))
            XCTAssertEqual(calendar.component(.hour, from: start), 1, entry.zone)
        }
    }

    func test_p124_autumnDateHasTwoMidnights() throws {
        let calendar = try gregorian("America/Havana")
        let start = calendar.startOfDay(for: try noon(autumnDate, calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: start), 0)
        let later = start.addingTimeInterval(3_600)
        XCTAssertEqual(calendar.component(.hour, from: later), 0)
        XCTAssertEqual(calendar.startOfDay(for: later), start)
    }

    func test_p124_dayLengthIsNotAlwaysTwentyFourHours() throws {
        for entry in springDates {
            let calendar = try gregorian(entry.zone)
            XCTAssertEqual(try dayLength(entry, calendar: calendar), 23 * 3_600, entry.zone)
        }
        let havana = try gregorian(autumnDate.zone)
        XCTAssertEqual(try dayLength(autumnDate, calendar: havana), 25 * 3_600)
    }

    // MARK: - п. 125

    func test_p125_duplicateRootKeyIsRejected() throws {
        let text = ManifestJSON.text(tail: ", \"schemaVersion\": 99")
        assertCorrupted(try decodeManifest(text), key: "schemaVersion")
    }

    func test_p125_duplicateNestedKeyNamesItsPath() throws {
        let markers = "[\(ManifestJSON.marker(atMs: "0")), " +
            "\(ManifestJSON.marker(atMs: "0", tail: ", \"atMs\": 5"))]"
        let path = corruptedPath(try decodeManifest(ManifestJSON.text(markers: markers)))
        XCTAssertEqual(path.last, "atMs")
        XCTAssertTrue(path.contains("markers"), "\(path)")
        XCTAssertTrue(path.contains("1"), "\(path)")
    }

    func test_p125_duplicateUnknownKeyIsRejected() throws {
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            tail: ", \"whatever\": 1, \"whatever\": 2")), key: "whatever")
    }

    /// Ложных срабатываний нет: одинаковые ключи в разных объектах и текст, похожий на
    /// повторённый ключ, внутри строкового значения — приняты.
    func test_p125_noFalsePositives() throws {
        let markers = "[\(ManifestJSON.marker(atMs: "0")), \(ManifestJSON.marker(atMs: "1"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: markers)))
        let tricky = ManifestJSON.marker(
            atMs: "0", detail: "\"\\\"atMs\\\": 1, \\\"atMs\\\": 2\"")
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: "[\(tricky)]")))
    }

    func test_p125_assertIsPublicAndRunsBeforeEverythingElse() throws {
        XCTAssertNoThrow(try DomainJSON.assertNoDuplicateKeys(in: Data(ManifestJSON.text().utf8)))
        let both = ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(sampleRate: "1e400"))]",
            tail: ", \"isFinalized\": false")
        assertCorrupted(try decodeManifest(both), key: "isFinalized")
    }

    // MARK: - п. 126

    func test_p126_dateBoundsAreSelfConsistent() throws {
        let lower = try decodeEvent(EventJSON.text(lastModified: "\"0001-01-01T00:00:00.000Z\""))
        XCTAssertTrue(try encodedText(lower).contains("0001-01-01T00:00:00.000Z"))
        let upper = try decodeEvent(EventJSON.text(lastModified: "\"9999-12-31T23:59:59.999Z\""))
        XCTAssertTrue(try encodedText(upper).contains("9999-12-31T23:59:59.999Z"))
    }

    func test_p126_outOfRangeFromJSONIsParseFailure() throws {
        for value in ["\"0001-01-01T00:00:00.000+14:00\"", "\"9999-12-31T23:59:59.99999Z\""] {
            assertCorrupted(try decodeEvent(EventJSON.text(lastModified: value)),
                            key: "lastModified")
        }
        let rounded = try decodeEvent(EventJSON.text(
            lastModified: "\"9999-12-31T23:59:59.9994Z\""))
        XCTAssertTrue(try encodedText(rounded).contains("9999-12-31T23:59:59.999Z"))
    }

    /// Двенадцать векторов, по два на каждое из шести полей `Date`.
    func test_p126_bothSidesOfRangeFromCode() throws {
        let above = Date(timeIntervalSince1970: 253_402_300_800)
        let below = Date(timeIntervalSince1970: -62_135_596_800.001)
        for (value, path) in [(above, "start"), (below, "start")] {
            assertInvariant(try DateProbe.event(start: value), contract: "C-001",
                            type: "MeetingEvent", invariant: 0, path: path)
        }
        for value in [above, below] {
            assertInvariant(try DateProbe.event(end: value), contract: "C-001",
                            type: "MeetingEvent", invariant: 0, path: "end")
            assertInvariant(try DateProbe.event(lastModified: value), contract: "C-001",
                            type: "MeetingEvent", invariant: 0, path: "lastModified")
            assertInvariant(try DateProbe.manifest(startedAt: value), contract: "C-002",
                            type: "RecordingManifest", invariant: 0, path: "startedAt")
            assertInvariant(try DateProbe.manifest(endedAt: value), contract: "C-002",
                            type: "RecordingManifest", invariant: 0, path: "endedAt")
            assertInvariant(try DateProbe.transcript(createdAt: value), contract: "C-003",
                            type: "Transcript", invariant: 0, path: "createdAt")
        }
    }

    /// `Date.distantPast` лежит на двое суток ниже границы: ICU-календарь `.gregorian`
    /// до 1582 года юлианский, а ISO-8601 пролептически григорианский.
    func test_p126_distantPastIsRejectedDistantFutureIsAccepted() throws {
        assertInvariant(try DateProbe.event(lastModified: .distantPast), contract: "C-001",
                        type: "MeetingEvent", invariant: 0, path: "lastModified")
        XCTAssertNoThrow(try DateProbe.event(lastModified: .distantFuture))
        XCTAssertNoThrow(try DateProbe.manifest(endedAt: nil))
    }

    func test_p126_millisecondBeyondBoundsIsRejected() throws {
        XCTAssertNoThrow(try DateProbe.event(lastModified:
            Date(timeIntervalSince1970: 253_402_300_799.999)))
        assertInvariant(try DateProbe.event(lastModified:
            Date(timeIntervalSince1970: 253_402_300_800.0)), contract: "C-001",
            type: "MeetingEvent", invariant: 0, path: "lastModified")
    }

    private func gregorian(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    private func noon(_ entry: DSTDate, calendar: Calendar) throws -> Date {
        var components = DateComponents()
        components.year = entry.year
        components.month = entry.month
        components.day = entry.day
        components.hour = 12
        return try XCTUnwrap(calendar.date(from: components))
    }

    private func dayLength(_ entry: DSTDate, calendar: Calendar) throws -> TimeInterval {
        let start = calendar.startOfDay(for: try noon(entry, calendar: calendar))
        let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        return calendar.startOfDay(for: next).timeIntervalSince(start)
    }
}

/// Дата перехода на летнее или зимнее время в названном поясе.
struct DSTDate {
    let zone: String
    let year: Int
    let month: Int
    let day: Int
}
