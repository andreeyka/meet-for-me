//  Раздел К перечня: фикстуры DomainTestKit, пп. 80—88.

import XCTest
import DomainCore
import DomainTestKit

final class FixtureTests: XCTestCase {

    func test_p80_fixtureSets_arePublicWithAllFixtures() {
        XCTAssertFalse(MeetingEventFixtures.allFixtures.isEmpty)
        XCTAssertFalse(RecordingManifestFixtures.allFixtures.isEmpty)
        XCTAssertFalse(TranscriptFixtures.allFixtures.isEmpty)
    }

    func test_p81_meetingEventFixtures_coverSevenCases() throws {
        XCTAssertEqual(MeetingEventFixtures.allFixtures.count, 8, "семь случаев, пара — двумя")
        XCTAssertNotNil(MeetingEventFixtures.oneOnOneZoom.conference)
        XCTAssertNil(MeetingEventFixtures.withoutConference.conference)
        XCTAssertTrue(MeetingEventFixtures.cancelled.isCancelled)
        XCTAssertEqual(MeetingEventFixtures.sameNameDifferentAddresses.attendees.count, 2)
        XCTAssertTrue(MeetingEventFixtures.allDayMoscow.isAllDay)
        XCTAssertTrue(MeetingEventFixtures.allDayWithoutMidnight.isAllDay)
    }

    /// Обе суточные фикстуры проверяются через `startOfDay`, а не через компоненты.
    func test_p81_allDayFixtures_areBuiltByInvariantSeven() throws {
        try assertFirstInstantOfDay(MeetingEventFixtures.allDayMoscow, expectedHour: 0,
                                    expectedSpan: 24 * 3_600)
        try assertFirstInstantOfDay(MeetingEventFixtures.allDayWithoutMidnight, expectedHour: 1,
                                    expectedSpan: 23 * 3_600)
    }

    func test_p82_duplicatePair_isUsableForDeduplication() throws {
        let first = MeetingEventFixtures.duplicateFromEventKit
        let second = MeetingEventFixtures.duplicateFromGraph
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.sourceConnectorId, second.sourceConnectorId)
        XCTAssertNotEqual(first.externalId, second.externalId)
        let uid = try XCTUnwrap(first.icalUid)
        XCTAssertFalse(uid.isEmpty)
        XCTAssertEqual(first.icalUid, second.icalUid)
        XCTAssertEqual(first.conference?.joinUrl, second.conference?.joinUrl)
    }

    func test_p83_sameNameFixture_hasEqualNamesAndDistinctAddresses() throws {
        let attendees = MeetingEventFixtures.sameNameDifferentAddresses.attendees
        XCTAssertEqual(attendees.count, 2)
        let names = attendees.map { $0.person.name }
        XCTAssertEqual(names.first, names.last)
        XCTAssertFalse(try XCTUnwrap(names.first ?? nil).isEmpty)
        let addresses = attendees.compactMap { $0.person.email }
        XCTAssertEqual(addresses.count, 2)
        XCTAssertNotEqual(addresses.first, addresses.last)
    }

    func test_p84_recordingManifestFixtures_coverSevenCases() throws {
        XCTAssertEqual(RecordingManifestFixtures.allFixtures.count, 7)
        XCTAssertEqual(RecordingManifestFixtures.hourlyTwoChannels.markers, [])

        let changed = RecordingManifestFixtures.deviceChangedMidway
        XCTAssertTrue(changed.markers.contains { $0.kind == .deviceChanged })
        XCTAssertTrue(changed.markers.contains { $0.kind == .discontinuity })
        let gap = try XCTUnwrap(changed.discontinuities.first)
        XCTAssertEqual(gap.reason, .rebuild)
        XCTAssertGreaterThanOrEqual(gap.scaleErrorMs, 150)
        XCTAssertEqual(changed.inputDevices.count, 2)
        XCTAssertEqual(changed.inputDevices.first?.atMs, 0)
        XCTAssertNotEqual(changed.inputDevices.first?.uid, changed.inputDevices.last?.uid)
        XCTAssertTrue(changed.inputDevices.allSatisfy(\.present))

        let unfinished = RecordingManifestFixtures.unfinished
        XCTAssertNil(unfinished.endedAt)
        XCTAssertFalse(unfinished.isFinalized)
        XCTAssertTrue(unfinished.tracks.allSatisfy { $0.format == "pcm-caf" })
        XCTAssertEqual(unfinished.inputDevices, [], "микрофона не было ни разу за запись")

        XCTAssertEqual(RecordingManifestFixtures.micOnly.tracks.count, 1)
        XCTAssertEqual(RecordingManifestFixtures.micOnly.tracks.first?.channel, .mic)
        XCTAssertFalse(RecordingManifestFixtures.micOnly.inputDevices.isEmpty)
    }

    func test_p84_sleepAndTruncatedAndNoMicrophone_expressTheirContent() throws {
        let sleeping = RecordingManifestFixtures.sleepDuringRecording
        let equalTimes = sleeping.markers.filter { $0.atMs == 1_800_000 }
        XCTAssertEqual(equalTimes.count, 2, "два маркера с равным atMs")
        XCTAssertEqual(sleeping.discontinuities.first?.reason, .sleep)

        let started = RecordingManifestFixtures.startedWithoutMicrophone
        let first = try XCTUnwrap(started.inputDevices.first)
        XCTAssertEqual(first.atMs, 0)
        XCTAssertFalse(first.present)
        XCTAssertNil(first.name)
        XCTAssertNil(first.uid)
        XCTAssertTrue(try XCTUnwrap(started.inputDevices.last).present)

        let truncated = RecordingManifestFixtures.truncatedRecovered
        let ended = try XCTUnwrap(truncated.endedAt)
        let duration = Int((ended.timeIntervalSince(truncated.startedAt) * 1000).rounded())
        XCTAssertEqual(truncated.discontinuities.last?.atMs, duration)
        XCTAssertEqual(truncated.discontinuities.last?.reason, .truncated)
        XCTAssertFalse(truncated.isFinalized)

        let keys = RecordingManifestFixtures.allFixtures.map(\.captureGroupKey)
        XCTAssertTrue(keys.contains { $0 != nil })
        XCTAssertTrue(keys.contains { $0 == nil })
    }

    func test_p85_transcriptFixtures_coverSixCases() throws {
        XCTAssertEqual(TranscriptFixtures.allFixtures.count, 6)
        XCTAssertEqual(TranscriptFixtures.oneOnOne.speakers.count, 1)
        XCTAssertTrue(hasCrossChannelOverlap(TranscriptFixtures.threeClustersOverlapping))
        XCTAssertEqual(Set(TranscriptFixtures.threeClustersOverlapping.speakers.map(\.cluster)).count, 3)
        XCTAssertTrue(TranscriptFixtures.withoutConfidence.segments.allSatisfy {
            $0.textConfidence == nil && $0.words.allSatisfy { $0.confidence == nil }
        })
        let corrected = try XCTUnwrap(TranscriptFixtures.withNameCorrections.segments.first)
        XCTAssertNotEqual(corrected.textOriginal, corrected.text)
        XCTAssertTrue(corrected.words.contains { $0.original != nil && $0.original != $0.text })
        let sparse = try XCTUnwrap(TranscriptFixtures.segmentWithoutWords.segments.first)
        XCTAssertEqual(sparse.words, [])
        XCTAssertNotNil(sparse.textConfidence)
        XCTAssertEqual(TranscriptFixtures.empty.segments, [])
    }

    func test_p85_fixturesWithEmbeddings_fillBothFields() {
        for transcript in TranscriptFixtures.allFixtures {
            for speaker in transcript.speakers where speaker.embedding != nil {
                XCTAssertNotNil(speaker.embeddingModelVersion)
            }
        }
    }

    func test_p86_allFixtures_areValid() throws {
        for fixture in MeetingEventFixtures.allFixtures {
            XCTAssertNoThrow(try fixture.validate())
            XCTAssertNoThrow(try DomainJSON.decode(MeetingEvent.self,
                                                   from: DomainJSON.encode(fixture)))
        }
        for fixture in RecordingManifestFixtures.allFixtures {
            XCTAssertNoThrow(try fixture.validate())
            XCTAssertNoThrow(try DomainJSON.decode(RecordingManifest.self,
                                                   from: DomainJSON.encode(fixture)))
        }
        for fixture in TranscriptFixtures.allFixtures {
            XCTAssertNoThrow(try fixture.validate())
            XCTAssertNoThrow(try DomainJSON.decode(Transcript.self,
                                                   from: DomainJSON.encode(fixture)))
        }
    }

    func test_p87_fixtures_areDeterministicAndMillisecondAligned() {
        XCTAssertEqual(MeetingEventFixtures.oneOnOneZoom, MeetingEventFixtures.oneOnOneZoom)
        XCTAssertEqual(RecordingManifestFixtures.micOnly, RecordingManifestFixtures.micOnly)
        XCTAssertEqual(TranscriptFixtures.oneOnOne, TranscriptFixtures.oneOnOne)
        XCTAssertEqual(MeetingEventFixtures.oneOnOneZoom.id.uuidString,
                       "11111111-1111-4111-8111-111111111111")
        for value in allFixtureDates() {
            let scaled = value.timeIntervalSince1970 * 1000
            XCTAssertEqual(scaled, scaled.rounded(), "\(value) не выровнена по миллисекунде")
        }
    }

    /// `DomainTestKit` собирается как обычная библиотека: типы её набора доступны отсюда,
    /// а XCTest она не импортирует — иначе от неё не смогли бы зависеть чужие таргеты.
    func test_p88_domainTestKit_isPlainLibrary() {
        let fixture: MeetingEvent = MeetingEventFixtures.oneOnOneZoom
        XCTAssertEqual(fixture.sourceConnectorId, "eventkit")
    }

    private func allFixtureDates() -> [Date] {
        var values: [Date] = []
        for event in MeetingEventFixtures.allFixtures {
            values.append(contentsOf: [event.start, event.end, event.lastModified])
        }
        for manifest in RecordingManifestFixtures.allFixtures {
            values.append(manifest.startedAt)
            if let ended = manifest.endedAt { values.append(ended) }
        }
        values.append(contentsOf: TranscriptFixtures.allFixtures.map(\.createdAt))
        return values
    }

    private func hasCrossChannelOverlap(_ transcript: Transcript) -> Bool {
        for first in transcript.segments {
            for second in transcript.segments
            where second.channel != first.channel
                && second.startMs < first.endMs && first.startMs < second.endMs {
                return true
            }
        }
        return false
    }

    private func assertFirstInstantOfDay(_ event: MeetingEvent, expectedHour: Int,
                                         expectedSpan: TimeInterval) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: event.timeZone))
        XCTAssertEqual(calendar.startOfDay(for: event.start), event.start)
        XCTAssertEqual(calendar.startOfDay(for: event.end), event.end)
        XCTAssertEqual(calendar.component(.hour, from: event.start), expectedHour)
        XCTAssertEqual(event.end.timeIntervalSince(event.start), expectedSpan)
    }
}
