//  MicChannelAndUserTests — MEE-382 группа Б, К6-К12: правило 1 (микрофонный канал),
//  confirm/reject (C-015 v9, инв. 6, 7, 9-12, 21а/21б).

import XCTest
import DomainCore
@testable import Attribution

final class MicChannelAndUserTests: XCTestCase {
    private let port = SpeakerAttribution()

    private func micAndSystemInput(me: PersonRecord?) throws -> AttributionInput {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .mic),
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0)])
        return Fixture.input(transcript: transcript, segmentIds: segmentIds, me: me)
    }

    func test_k6_micChannelRuleWithAndWithoutMe() async throws {
        let me = Fixture.person(1, name: "Я", isMe: true)

        let withMe = try micAndSystemInput(me: me)
        let withMeResult = try await port.attribute(withMe, thresholds: .slice1Defaults)
        let withMeUpdate = try XCTUnwrap(withMeResult.segmentUpdates.first { $0.segmentId == 1 })
        XCTAssertEqual(withMeUpdate.attributionSource, .micChannel)
        XCTAssertEqual(withMeUpdate.personId, me.id)
        XCTAssertEqual(withMeUpdate.speakerConfidence, 1.0)

        let withoutMe = try micAndSystemInput(me: nil)
        let withoutMeResult = try await port.attribute(withoutMe, thresholds: .slice1Defaults)
        let withoutMeUpdate = try XCTUnwrap(withoutMeResult.segmentUpdates.first { $0.segmentId == 1 })
        XCTAssertEqual(withoutMeUpdate.attributionSource, .micChannel)
        XCTAssertNil(withoutMeUpdate.personId)
        XCTAssertEqual(withoutMeUpdate.speakerConfidence, 0.0)

        XCTAssertFalse(withMeResult.assignments.contains { $0.source == .micChannel })

        let confirmed = try await port.confirm(
            transcriptId: withMe.transcriptId, cluster: 0, personId: me.id, input: withMe
        )
        let rejected = try await port.reject(transcriptId: withMe.transcriptId, cluster: 0, input: withMe)
        XCTAssertFalse(confirmed.assignments.contains { $0.source == .micChannel })
        XCTAssertFalse(rejected.assignments.contains { $0.source == .micChannel })
    }

    func test_k7_userSourceOnlyFromConfirmAndReject() async throws {
        let me = Fixture.person(1, name: "Я", isMe: true)
        let input = try micAndSystemInput(me: me)

        let attributed = try await port.attribute(input, thresholds: .slice1Defaults)
        XCTAssertFalse(attributed.assignments.contains { $0.source == .user })

        let confirmed = try await port.confirm(
            transcriptId: input.transcriptId, cluster: 0, personId: me.id, input: input
        )
        let confirmedAssignment = try XCTUnwrap(confirmed.assignments.first { $0.cluster == 0 })
        XCTAssertEqual(confirmedAssignment.source, .user)

        let rejected = try await port.reject(transcriptId: input.transcriptId, cluster: 0, input: input)
        let rejectedAssignment = try XCTUnwrap(rejected.assignments.first { $0.cluster == 0 })
        XCTAssertEqual(rejectedAssignment.source, .user)
    }

    func test_k8_attributeNeverTouchesProfiles() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0, embedding: [1.0, 0.0])])
        let profile = Fixture.profile(1, embedding: [1.0, 0.0])
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds, profiles: [profile])

        let result = try await port.attribute(input, thresholds: .slice1Defaults)

        XCTAssertTrue(result.profileUpdates.isEmpty)
    }

    func test_k9_confirmUpdatesProfileWeightedAverageNormalized() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0, embedding: [1.0, 0.0])])
        let personId = Fixture.uuid(1)
        let existing = SpeakerProfile(
            personId: personId, embedding: [0.0, 1.0], modelVersion: "v1", sampleCount: 4, updatedAt: Fixture.createdAt
        )
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds, profiles: [existing])

        let result = try await port.confirm(
            transcriptId: input.transcriptId, cluster: 0, personId: personId, input: input
        )

        XCTAssertEqual(result.profileUpdates.count, 1)
        let update = try XCTUnwrap(result.profileUpdates.first)
        XCTAssertEqual(update.sampleCount, 5)
        XCTAssertEqual(update.personId, personId)
        XCTAssertEqual(update.embedding[0], 0.242536, accuracy: 0.0001)
        XCTAssertEqual(update.embedding[1], 0.970143, accuracy: 0.0001)
        let length = (update.embedding.reduce(0.0) { $0 + Double($1) * Double($1) }).squareRoot()
        XCTAssertEqual(length, 1.0, accuracy: 0.0001)
    }

    func test_k10_unknownPersonScopedToAttendeesAndMeNotDatabase() async throws {
        let me = Fixture.person(1, name: "Я", isMe: true)
        let attendee = Fixture.person(2, name: "Второй")
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0)])
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds, attendees: [attendee], me: me)

        do {
            _ = try await port.confirm(
                transcriptId: input.transcriptId, cluster: 0, personId: Fixture.uuid(99), input: input
            )
            XCTFail("обязан бросить unknownPerson")
        } catch AttributionError.unknownPerson(let personId) {
            XCTAssertEqual(personId, Fixture.uuid(99))
        }

        _ = try await port.confirm(transcriptId: input.transcriptId, cluster: 0, personId: me.id, input: input)

        do {
            _ = try await port.confirm(
                transcriptId: input.transcriptId, cluster: 99, personId: attendee.id, input: input
            )
            XCTFail("обязан бросить unknownCluster")
        } catch AttributionError.unknownCluster(let cluster) {
            XCTAssertEqual(cluster, 99)
        }
    }

    func test_k11_rejectClearsAssignmentAndSetsUserSource() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0, embedding: [1.0, 0.0])])
        let profile = Fixture.profile(1, embedding: [0.0, 1.0])
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds, profiles: [profile])

        let result = try await port.reject(transcriptId: input.transcriptId, cluster: 0, input: input)

        let assignment = try XCTUnwrap(result.assignments.first { $0.cluster == 0 })
        XCTAssertNil(assignment.personId)
        XCTAssertEqual(assignment.confidence, 0.0)
        XCTAssertEqual(assignment.source, .user)
        XCTAssertTrue(result.profileUpdates.isEmpty)
    }

    func test_k12_micSegmentUpdateCarriesRule1Values() async throws {
        let me = Fixture.person(1, name: "Я", isMe: true)
        let input = try micAndSystemInput(me: me)

        let result = try await port.attribute(input, thresholds: .slice1Defaults)

        let micUpdates = result.segmentUpdates.filter { $0.attributionSource == .micChannel }
        XCTAssertEqual(micUpdates.count, 1)
        XCTAssertEqual(micUpdates[0].personId, me.id)
        XCTAssertEqual(micUpdates[0].speakerConfidence, 1.0)
    }
}
