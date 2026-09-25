//  AttributeJobHandlerInputTests — К24–К34 перечня MEE-382, группа К плана MEE-396:
//  построение `AttributionInput`, поле за полем (C-015 §7 v10), владелец: DEV-2.

import XCTest
import DomainCore
import DomainTestKit

final class AttributeJobHandlerInputTests: XCTestCase {

    // MARK: - К24 (transcriptId дословно)

    func test_k24_transcriptIdPassedThroughVerbatim() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: transcriptId)

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(harness.port.lastAttributedInput?.transcriptId, transcriptId)
    }

    // MARK: - К25 (транскрипт не найден)

    func test_k25_missingTranscriptIsPermanentFailureWithoutPortCall() async throws {
        let harness = AttributeHarness()
        let outcome = await harness.run(AttributeFixture.job(transcriptId: UUID(), meetingId: nil))

        assertPermanentFailure(outcome)
        XCTAssertEqual(harness.port.attributeCallCount, 0)
    }

    // MARK: - К26 (segmentIds по порядку, userEditedSegmentIds — подмножество)

    func test_k26_segmentIdsOrderedAndUserEditedSubsetCorrect() async throws {
        let harness = AttributeHarness()
        let segments = try (0..<5).map { index in
            try AttributeFixture.segment(
                words: [try AttributeFixture.word("word\(index)")],
                start: index * 1_000, end: index * 1_000 + 1_000
            )
        }
        let transcript = try AttributeFixture.transcript(segments: segments)
        let transcriptId = try await harness.seedTranscript(transcript)
        let rows = try await harness.transcripts.segments(transcriptId: transcriptId)
        let editedIds = [rows[1].id, rows[3].id]
        for id in editedIds {
            try await harness.transcripts.updateSegmentText(segmentId: id, text: "правка", isUserEdited: true)
        }
        harness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: transcriptId)

        _ = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        let input = try XCTUnwrap(harness.port.lastAttributedInput)
        XCTAssertEqual(input.segmentIds, rows.map(\.id), "тот же порядок, что transcript.segments")
        XCTAssertEqual(Set(input.userEditedSegmentIds), Set(editedIds))
    }

    // MARK: - К27 (meetingId дословно)

    func test_k27_meetingIdPassedThroughVerbatim() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        let meetingEvent = try AttributeFixture.meetingEvent(id: UUID(), attendees: [])
        try await harness.meetings.save(MeetingRecord(
            event: meetingEvent, dedupKey: nil, status: .scheduled, sources: []
        ))
        harness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: transcriptId)

        _ = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: meetingEvent.id))

        XCTAssertEqual(harness.port.lastAttributedInput?.meetingId, meetingEvent.id)
    }

    // MARK: - К28 (meetingId == nil — MeetingRepository не вызван, attendees пуст)

    func test_k28_nilMeetingIdSkipsMeetingRepositoryEmptyAttendees() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: transcriptId)

        _ = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))

        XCTAssertEqual(harness.log.count(port: "MeetingRepository", method: "meeting(id:)"), 0)
        XCTAssertEqual(harness.port.lastAttributedInput?.attendees, [])
    }

    // MARK: - К29 (встреча удалена между постановкой и выполнением — тот же исход, что К28)

    func test_k29_meetingNotFoundYieldsEmptyAttendeesNotJobFailure() async throws {
        let harness = AttributeHarness()
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: transcriptId)

        let outcome = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: UUID()))

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(harness.port.lastAttributedInput?.attendees, [])
    }

    // MARK: - К30 (адреса без карточки выпадают молча)

    func test_k30_unresolvedAttendeeEmailsDroppedSilently() async throws {
        let harness = AttributeHarness()
        let alice = AttributeFixture.person(name: "Alice", email: "alice@example.com")
        let bob = AttributeFixture.person(name: "Bob", email: "bob@example.com")
        harness.persons.seed([alice, bob])
        let attendees = try [
            AttributeFixture.attendee(person: alice),
            AttributeFixture.attendee(person: bob),
            AttributeFixture.attendeeWithoutEmail(name: "Carol")
        ]
        let meetingEvent = try AttributeFixture.meetingEvent(id: UUID(), attendees: attendees)
        try await harness.meetings.save(MeetingRecord(
            event: meetingEvent, dedupKey: nil, status: .scheduled, sources: []
        ))
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: transcriptId)

        _ = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: meetingEvent.id))

        let resolved = try XCTUnwrap(harness.port.lastAttributedInput?.attendees)
        XCTAssertEqual(Set(resolved.map(\.id)), Set([alice.id, bob.id]))
    }

    // MARK: - К31 (me() дословно или nil)

    func test_k31_meFromPersonRepositoryVerbatimOrNil() async throws {
        let harness = AttributeHarness()
        let me = AttributeFixture.person(name: "Me", email: "me@example.com", isMe: true)
        harness.persons.seed([me])
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: transcriptId)

        _ = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: nil))
        XCTAssertEqual(harness.port.lastAttributedInput?.me?.id, me.id)

        let harnessWithoutMe = AttributeHarness()
        let secondTranscriptId = try await harnessWithoutMe.seedTranscript(transcript)
        harnessWithoutMe.port.forcedResult = AttributeFixture.emptyResult(transcriptId: secondTranscriptId)
        _ = await harnessWithoutMe.run(AttributeFixture.job(transcriptId: secondTranscriptId, meetingId: nil))
        XCTAssertNil(harnessWithoutMe.port.lastAttributedInput?.me, "me() → nil, не отказ")
    }

    // MARK: - К32 (nameForms по объединению attendees и me)

    func test_k32_nameFormsQueriedForUnionOfAttendeesAndMe() async throws {
        let harness = AttributeHarness()
        let alice = AttributeFixture.person(name: "Alice", email: "alice@example.com")
        let me = AttributeFixture.person(name: "Me", email: "me@example.com", isMe: true)
        harness.persons.seed([alice, me])
        let meetingEvent = try AttributeFixture.meetingEvent(
            id: UUID(), attendees: [try AttributeFixture.attendee(person: alice)]
        )
        try await harness.meetings.save(MeetingRecord(
            event: meetingEvent, dedupKey: nil, status: .scheduled, sources: []
        ))
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let transcriptId = try await harness.seedTranscript(transcript)
        harness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: transcriptId)

        _ = await harness.run(AttributeFixture.job(transcriptId: transcriptId, meetingId: meetingEvent.id))

        let call = harness.log.calls(port: "PersonRepository").first { $0.method == "nameForms(personIds:)" }
        let queriedIds = Set(try XCTUnwrap(call).arguments)
        XCTAssertEqual(queriedIds, Set([alice.id.uuidString, me.id.uuidString]))
    }

    // MARK: - К33 (voiceProfilesEnabled дословно, гейт profiles)

    func test_k33_voiceProfilesEnabledPassedThroughAndGatesProfilesFetch() async throws {
        let disabled = AttributeHarness()
        disabled.voiceProfilesEnabledValue = false
        let transcript = try AttributeFixture.transcript(segments: [
            try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])
        ])
        let disabledTranscriptId = try await disabled.seedTranscript(transcript)
        disabled.port.forcedResult = AttributeFixture.emptyResult(transcriptId: disabledTranscriptId)
        _ = await disabled.run(AttributeFixture.job(transcriptId: disabledTranscriptId, meetingId: nil))
        XCTAssertEqual(disabled.port.lastAttributedInput?.voiceProfilesEnabled, false)
        XCTAssertEqual(disabled.port.lastAttributedInput?.profiles, [])
        XCTAssertEqual(
            disabled.log.count(port: "SpeakerProfileRepository", method: "profiles(personIds:modelVersion:)"), 0
        )

        let enabled = AttributeHarness()
        enabled.voiceProfilesEnabledValue = true
        let me = AttributeFixture.person(name: "Me", email: "me@example.com", isMe: true)
        enabled.persons.seed([me])
        let profile = SpeakerProfile(
            personId: me.id, embedding: [0.1, 0.2], modelVersion: "v1",
            sampleCount: 3, updatedAt: AttributeFixture.epoch
        )
        enabled.speakerProfiles.seed([profile])
        let speakerTranscript = try AttributeFixture.transcript(
            segments: [try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])],
            speakers: [try AttributeFixture.speaker(cluster: 0, embeddingModelVersion: "v1")]
        )
        let enabledTranscriptId = try await enabled.seedTranscript(speakerTranscript)
        enabled.port.forcedResult = AttributeFixture.emptyResult(transcriptId: enabledTranscriptId)
        _ = await enabled.run(AttributeFixture.job(transcriptId: enabledTranscriptId, meetingId: nil))
        XCTAssertEqual(enabled.port.lastAttributedInput?.voiceProfilesEnabled, true)
        XCTAssertEqual(enabled.port.lastAttributedInput?.profiles, [profile])
    }

    // MARK: - К34 (embeddingModelVersion — первая непустая, либо permanentFailure)

    func test_k34_firstNonEmptyEmbeddingVersionOrPermanentFailureIfNoneAndSpeakersNonEmpty() async throws {
        // (a) первая непустая версия среди спикеров.
        let firstVersionHarness = AttributeHarness()
        let mixedTranscript = try AttributeFixture.transcript(
            segments: [try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])],
            speakers: [
                try AttributeFixture.speaker(cluster: 0, embeddingModelVersion: nil),
                try AttributeFixture.speaker(cluster: 1, embeddingModelVersion: "v2")
            ]
        )
        let mixedTranscriptId = try await firstVersionHarness.seedTranscript(mixedTranscript)
        firstVersionHarness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: mixedTranscriptId)
        _ = await firstVersionHarness.run(AttributeFixture.job(transcriptId: mixedTranscriptId, meetingId: nil))
        XCTAssertEqual(firstVersionHarness.port.lastAttributedInput?.embeddingModelVersion, "v2")

        // (b) спикеры есть, версии нет ни у одного — испорченный вход, порт не вызван.
        let corruptedHarness = AttributeHarness()
        let corruptedTranscript = try AttributeFixture.transcript(
            segments: [try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])],
            speakers: [try AttributeFixture.speaker(cluster: 0, embeddingModelVersion: nil)]
        )
        let corruptedTranscriptId = try await corruptedHarness.seedTranscript(corruptedTranscript)
        let outcome = await corruptedHarness.run(
            AttributeFixture.job(transcriptId: corruptedTranscriptId, meetingId: nil)
        )
        assertPermanentFailure(outcome)
        XCTAssertEqual(corruptedHarness.port.attributeCallCount, 0)

        // (c) speakers пуст — штатный вход, версия "".
        let emptySpeakersHarness = AttributeHarness()
        let micOnlyTranscript = try AttributeFixture.transcript(
            segments: [try AttributeFixture.segment(words: [try AttributeFixture.word("hi")])]
        )
        let micOnlyTranscriptId = try await emptySpeakersHarness.seedTranscript(micOnlyTranscript)
        emptySpeakersHarness.port.forcedResult = AttributeFixture.emptyResult(transcriptId: micOnlyTranscriptId)
        let micOutcome = await emptySpeakersHarness.run(
            AttributeFixture.job(transcriptId: micOnlyTranscriptId, meetingId: nil)
        )
        XCTAssertEqual(micOutcome, .success)
        XCTAssertEqual(emptySpeakersHarness.port.lastAttributedInput?.embeddingModelVersion, "")
    }
}
