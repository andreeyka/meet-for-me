//  RulesAndEdgeCasesTests — MEE-382 группа Е (К20) и группа О (К44-К47, К50): единственный
//  путь эмбеддинга наружу, форма userEditedSegmentIds (инв. 23), правила 2-4 §5, confirm при
//  выключенных голосовых профилях (инв. 10, вторая часть).

import XCTest
import DomainCore
@testable import Attribution

final class RulesAndEdgeCasesTests: XCTestCase {
    private let port = SpeakerAttribution()

    func test_k20_embeddingLeavesOnlyThroughProfileUpdates() async throws {
        let person = Fixture.person(1, name: "Иван")
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0, embedding: [1.0, 0.0])])
        let existing = Fixture.profile(1, embedding: [0.0, 1.0])
        let input = Fixture.input(
            transcript: transcript, segmentIds: segmentIds, attendees: [person], profiles: [existing]
        )

        let confirmed = try await port.confirm(
            transcriptId: input.transcriptId, cluster: 0, personId: person.id, input: input
        )
        XCTAssertEqual(confirmed.profileUpdates.count, 1)
        XCTAssertFalse(confirmed.profileUpdates[0].embedding.isEmpty)

        let attributed = try await port.attribute(input, thresholds: .slice1Defaults)
        XCTAssertTrue(attributed.profileUpdates.isEmpty)

        let rejected = try await port.reject(transcriptId: input.transcriptId, cluster: 0, input: input)
        XCTAssertTrue(rejected.profileUpdates.isEmpty)
    }

    func test_k44_foreignOrDuplicateUserEditedIdsIgnoredSilently() async throws {
        let transcriptId = Fixture.uuid(1)
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0)])
        let baseline = try await port.attribute(
            Fixture.input(transcriptId: transcriptId, transcript: transcript, segmentIds: segmentIds),
            thresholds: .slice1Defaults
        )

        let withForeignId = try await port.attribute(
            Fixture.input(
                transcriptId: transcriptId, transcript: transcript, segmentIds: segmentIds,
                userEditedSegmentIds: [999]
            ),
            thresholds: .slice1Defaults
        )
        XCTAssertEqual(withForeignId, baseline)

        let withSingleId = try await port.attribute(
            Fixture.input(
                transcriptId: transcriptId, transcript: transcript, segmentIds: segmentIds,
                userEditedSegmentIds: [1]
            ),
            thresholds: .slice1Defaults
        )
        let withDuplicateId = try await port.attribute(
            Fixture.input(
                transcriptId: transcriptId, transcript: transcript, segmentIds: segmentIds,
                userEditedSegmentIds: [1, 1]
            ),
            thresholds: .slice1Defaults
        )
        XCTAssertEqual(withDuplicateId, withSingleId, "повтор валидного id не меняет ответ по сравнению с одним разом")
    }

    func test_k45_rule2VoiceProfileMatchAndMarginReject() async throws {
        let personA = Fixture.uuid(1)
        let personB = Fixture.uuid(2)
        let (passingTranscript, passingSegmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0, embedding: [1.0, 0.0])])
        let passingInput = Fixture.input(
            transcript: passingTranscript, segmentIds: passingSegmentIds,
            profiles: [
                SpeakerProfile(
                    personId: personA, embedding: [0.9, 0.4358899], modelVersion: "v1",
                    sampleCount: 1, updatedAt: Fixture.createdAt
                ),
                SpeakerProfile(
                    personId: personB, embedding: [0.7, 0.7141428], modelVersion: "v1",
                    sampleCount: 1, updatedAt: Fixture.createdAt
                )
            ]
        )
        let passingResult = try await port.attribute(passingInput, thresholds: .slice1Defaults)
        let passingAssignment = try XCTUnwrap(passingResult.assignments.first)
        XCTAssertEqual(passingAssignment.personId, personA)
        XCTAssertEqual(passingAssignment.confidence, 0.90, accuracy: 0.001)
        XCTAssertEqual(passingAssignment.source, .voiceProfile)
        XCTAssertEqual(passingAssignment.runnerUp?.personId, personB)

        let personC = Fixture.uuid(3)
        let personD = Fixture.uuid(4)
        let (rejectingTranscript, rejectingSegmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0, embedding: [1.0, 0.0])])
        let rejectingInput = Fixture.input(
            transcript: rejectingTranscript, segmentIds: rejectingSegmentIds,
            profiles: [
                SpeakerProfile(
                    personId: personC, embedding: [0.82, 0.5723635], modelVersion: "v1",
                    sampleCount: 1, updatedAt: Fixture.createdAt
                ),
                SpeakerProfile(
                    personId: personD, embedding: [0.79, 0.6131068], modelVersion: "v1",
                    sampleCount: 1, updatedAt: Fixture.createdAt
                )
            ]
        )
        let rejectingResult = try await port.attribute(rejectingInput, thresholds: .slice1Defaults)
        let rejectingAssignment = try XCTUnwrap(rejectingResult.assignments.first)
        XCTAssertNil(
            rejectingAssignment.personId, "разрыв 0.03 меньше profileMatchMargin 0.05 — правило 2 не срабатывает"
        )
    }

    func test_k46_rule3OneOnOneOnlyWithExactlyOneSystemCluster() async throws {
        let me = Fixture.person(1, name: "Я", isMe: true)
        let other = Fixture.person(2, name: "Второй")

        let (oneClusterTranscript, oneClusterSegmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0)])
        let oneClusterInput = Fixture.input(
            transcript: oneClusterTranscript, segmentIds: oneClusterSegmentIds, attendees: [me, other], me: me
        )
        let oneClusterResult = try await port.attribute(oneClusterInput, thresholds: .slice1Defaults)
        let assignment = try XCTUnwrap(oneClusterResult.assignments.first)
        XCTAssertEqual(assignment.personId, other.id)
        XCTAssertEqual(assignment.confidence, 0.95)
        XCTAssertEqual(assignment.source, .oneOnOne)

        let (twoClustersTranscript, twoClustersSegmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0), SegmentSpec(channel: .system, cluster: 1)
        ], speakers: [try Fixture.speaker(0), try Fixture.speaker(1)])
        let twoClustersInput = Fixture.input(
            transcript: twoClustersTranscript, segmentIds: twoClustersSegmentIds, attendees: [me, other], me: me
        )
        let twoClustersResult = try await port.attribute(twoClustersInput, thresholds: .slice1Defaults)
        XCTAssertTrue(
            twoClustersResult.assignments.allSatisfy { $0.personId == nil },
            "два кластера — правило 3 не срабатывает ни для одного"
        )
    }

    func test_k47_rule4UnassignedSourceDependsOnWhetherProfilesWereCompared() async throws {
        let profile = Fixture.profile(1, embedding: [0.0, 1.0])
        let (comparedTranscript, comparedSegmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0, embedding: [1.0, 0.0])])
        let comparedInput = Fixture.input(
            transcript: comparedTranscript, segmentIds: comparedSegmentIds, profiles: [profile]
        )
        let comparedResult = try await port.attribute(comparedInput, thresholds: .slice1Defaults)
        let comparedAssignment = try XCTUnwrap(comparedResult.assignments.first)
        XCTAssertNil(comparedAssignment.personId)
        XCTAssertEqual(comparedAssignment.source, .voiceProfile)

        let (uncomparedTranscript, uncomparedSegmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0)])
        let uncomparedInput = Fixture.input(transcript: uncomparedTranscript, segmentIds: uncomparedSegmentIds)
        let uncomparedResult = try await port.attribute(uncomparedInput, thresholds: .slice1Defaults)
        let uncomparedAssignment = try XCTUnwrap(uncomparedResult.assignments.first)
        XCTAssertNil(uncomparedAssignment.personId)
        XCTAssertEqual(uncomparedAssignment.source, .oneOnOne)
    }

    func test_k50_confirmSucceedsWithoutProfileTrainingWhenVoiceProfilesDisabled() async throws {
        let person = Fixture.person(1, name: "Иван")
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0, embedding: [1.0, 0.0])])
        let existing = Fixture.profile(1, embedding: [0.0, 1.0])
        let input = Fixture.input(
            transcript: transcript, segmentIds: segmentIds, attendees: [person],
            profiles: [existing], voiceProfilesEnabled: false
        )

        let result = try await port.confirm(
            transcriptId: input.transcriptId, cluster: 0, personId: person.id, input: input
        )

        let assignment = try XCTUnwrap(result.assignments.first { $0.cluster == 0 })
        XCTAssertEqual(assignment.personId, person.id)
        XCTAssertEqual(assignment.source, .user)
        XCTAssertTrue(result.profileUpdates.isEmpty, "выключенные профили — обучение не происходит, но вызов успешен")
    }
}
