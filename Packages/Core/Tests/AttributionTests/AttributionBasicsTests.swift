//  AttributionBasicsTests — MEE-382 группа А, К1-К5: вход и базовые инварианты attribute()
//  (C-015 v9, инв. 1-5).

import XCTest
import DomainCore
@testable import Attribution

final class AttributionBasicsTests: XCTestCase {
    private let port = SpeakerAttribution()

    func test_k1_attributeIsDeterministicAcrossRepeatedCalls() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0)])
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds)

        let first = try await port.attribute(input, thresholds: .slice1Defaults)
        let second = try await port.attribute(input, thresholds: .slice1Defaults)
        XCTAssertEqual(first, second)

        // `otherInput` разделяет с `input` тот же дефолтный `transcriptId` (Fixture.input,
        // MEE-411) — неравенство ниже обязано доказываться содержимым (другое число
        // кластеров), а не случайным транскрипт-id, который раньше делал бы assert зелёным
        // при любом содержимом.
        let (otherTranscript, otherSegmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0), SegmentSpec(channel: .system, cluster: 1)
        ], speakers: [try Fixture.speaker(0), try Fixture.speaker(1)])
        let otherInput = Fixture.input(transcript: otherTranscript, segmentIds: otherSegmentIds)
        XCTAssertEqual(otherInput.transcriptId, input.transcriptId)
        let third = try await port.attribute(otherInput, thresholds: .slice1Defaults)
        XCTAssertNotEqual(third.assignments.count, first.assignments.count)
        XCTAssertNotEqual(third, first, "иной вход обязан дать независимый результат")
    }

    func test_k2_segmentIdsCountMismatchThrows() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0), SegmentSpec(channel: .system, cluster: 1)
        ], speakers: [try Fixture.speaker(0), try Fixture.speaker(1)])

        let tooFew = Fixture.input(transcript: transcript, segmentIds: Array(segmentIds.dropLast()))
        do {
            _ = try await port.attribute(tooFew, thresholds: .slice1Defaults)
            XCTFail("обязан бросить segmentIdsMismatch")
        } catch AttributionError.segmentIdsMismatch(let expected, let actual) {
            XCTAssertEqual(expected, 1)
            XCTAssertEqual(actual, 2)
        }

        let tooMany = Fixture.input(transcript: transcript, segmentIds: segmentIds + [99])
        do {
            _ = try await port.attribute(tooMany, thresholds: .slice1Defaults)
            XCTFail("обязан бросить segmentIdsMismatch")
        } catch AttributionError.segmentIdsMismatch(let expected, let actual) {
            XCTAssertEqual(expected, 3)
            XCTAssertEqual(actual, 2)
        }
    }

    func test_k3_embeddingModelMismatchRejectsWholeCallNotPartially() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0, embedding: [1.0, 0.0], version: "v1")])

        let foreignVersionProfile = Fixture.profile(1, embedding: [1.0, 0.0], version: "v2")
        let wrongVersionInput = Fixture.input(
            transcript: transcript, segmentIds: segmentIds, profiles: [foreignVersionProfile]
        )
        await assertThrowsMismatch(wrongVersionInput)

        let unrelatedPersonProfile = Fixture.profile(2, embedding: [0.0, 1.0], version: "v2")
        let unrelatedInput = Fixture.input(
            transcript: transcript, segmentIds: segmentIds, profiles: [unrelatedPersonProfile]
        )
        await assertThrowsMismatch(unrelatedInput)

        let validProfile = Fixture.profile(3, embedding: [1.0, 0.0], version: "v1")
        let mixedInput = Fixture.input(
            transcript: transcript, segmentIds: segmentIds, profiles: [validProfile, foreignVersionProfile]
        )
        await assertThrowsMismatch(mixedInput, "валидный профиль не спасает вызов — отказ не выборочный")
    }

    private func assertThrowsMismatch(_ input: AttributionInput, _ message: String = "") async {
        do {
            _ = try await port.attribute(input, thresholds: .slice1Defaults)
            XCTFail("обязан бросить embeddingModelMismatch. \(message)")
        } catch AttributionError.embeddingModelMismatch {
            // ожидаемо
        } catch {
            XCTFail("не тот отказ: \(error)")
        }
    }

    func test_k4_assignmentsCoverEveryClusterExactlyOnce() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0),
            SegmentSpec(channel: .system, cluster: 1),
            SegmentSpec(channel: .system, cluster: 2)
        ], speakers: [try Fixture.speaker(0), try Fixture.speaker(1), try Fixture.speaker(2)])
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds)

        let result = try await port.attribute(input, thresholds: .slice1Defaults)

        XCTAssertEqual(result.assignments.count, 3)
        XCTAssertEqual(Set(result.assignments.map(\.cluster)), Set([0, 1, 2]))
    }

    func test_k5_confidenceInRangeAndZeroWhenPersonIdNil() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0)])
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds)

        let result = try await port.attribute(input, thresholds: .slice1Defaults)

        for assignment in result.assignments {
            XCTAssertTrue((0.0...1.0).contains(assignment.confidence))
            if assignment.personId == nil {
                XCTAssertEqual(assignment.confidence, 0.0)
            }
        }
    }
}
