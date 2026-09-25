//  CosineAndCollectionsTests — MEE-382 группа Г, К18-К19: инв. 17 (косинусное сходство только
//  между векторами одной длины) и инв. 22 (какая единица едет в какую коллекцию, независимо
//  от канала — три части, плюс исключения инв. 16 и инв. 8 внутри части (б)).

import XCTest
import DomainCore
@testable import Attribution

final class CosineAndCollectionsTests: XCTestCase {
    private let port = SpeakerAttribution()

    func test_k18_mismatchedEmbeddingLengthsTreatedAsVersionMismatch() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0, embedding: Array(repeating: Float(0.1), count: 192))])
        let profile = Fixture.profile(1, embedding: Array(repeating: Float(0.1), count: 256))
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds, profiles: [profile])

        do {
            _ = try await port.attribute(input, thresholds: .slice1Defaults)
            XCTFail("обязан бросить embeddingModelMismatch")
        } catch AttributionError.embeddingModelMismatch {
            // ожидаемо — вектор другой длины при совпавшей версии
        }
    }

    /// Шесть сегментов: два несут кластер (0, 1) — (а)/(в); один микрофонный — кластера нет,
    /// в assignments не попадает никогда; один системный из пробелов без кластера — граница
    /// (б), не едет никуда; один с кластером (2), не опознанным ни одним правилом, и заменой
    /// слова — исключение инв. 16 внутри (б); один с кластером (3), тоже неопознанным, но его
    /// `segmentId` в `userEditedSegmentIds` — исключение инв. 8 внутри (б).
    func test_k19_assignmentsAndSegmentUpdatesConsistentAcrossSevenInputs() async throws {
        let anna = Fixture.uuid(1)
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0),
            SegmentSpec(channel: .system, cluster: 1),
            SegmentSpec(channel: .mic),
            SegmentSpec(channel: .system, cluster: nil, text: "   "),
            SegmentSpec(channel: .system, cluster: 2, words: [("Анна.", 0.4)]),
            SegmentSpec(channel: .system, cluster: 3)
        ], speakers: [
            try Fixture.speaker(0), try Fixture.speaker(1), try Fixture.speaker(2), try Fixture.speaker(3)
        ])
        let userEditedSegmentId = segmentIds[5]
        let input = Fixture.input(
            transcript: transcript, segmentIds: segmentIds,
            nameForms: [NameForm(personId: anna, form: "Анна", kind: .full)],
            userEditedSegmentIds: [userEditedSegmentId]
        )

        let result = try await port.attribute(input, thresholds: .slice1Defaults)

        // (а): ровно по одному элементу на каждый кластер транскрипта, ничего сверх.
        XCTAssertEqual(Set(result.assignments.map(\.cluster)), Set([0, 1, 2, 3]))
        XCTAssertFalse(result.assignments.contains { $0.source == .micChannel })

        let bySegmentId = Dictionary(uniqueKeysWithValues: result.segmentUpdates.map { ($0.segmentId, $0) })

        // (б): микрофонный сегмент — значения правила 1.
        let micUpdate = try XCTUnwrap(bySegmentId[segmentIds[2]])
        XCTAssertEqual(micUpdate.attributionSource, .micChannel)

        // Граница (б): системный сегмент из пробелов без кластера не едет никуда.
        XCTAssertNil(bySegmentId[segmentIds[3]])

        // Исключение инв. 16 внутри (б): кластер 2 не опознан, но получил замену слова —
        // источник строки `nameDictionary`, значения назначения (personId/confidence) те же.
        let correctedUpdate = try XCTUnwrap(bySegmentId[segmentIds[4]])
        let cluster2Assignment = try XCTUnwrap(result.assignments.first { $0.cluster == 2 })
        XCTAssertEqual(correctedUpdate.attributionSource, .nameDictionary)
        XCTAssertEqual(correctedUpdate.personId, cluster2Assignment.personId)
        XCTAssertEqual(correctedUpdate.speakerConfidence, cluster2Assignment.confidence)
        XCTAssertNotEqual(
            correctedUpdate.attributionSource, cluster2Assignment.source,
            "исключение — «чужое», не второе на assignments"
        )

        // Исключение инв. 8 внутри (б): кластер 3 правлен пользователем — в assignments есть
        // (адресация по кластеру), в segmentUpdates — нет (адресация по строке).
        XCTAssertTrue(result.assignments.contains { $0.cluster == 3 })
        XCTAssertNil(bySegmentId[userEditedSegmentId])

        // (в): сегменты с кластером 0/1 — в обеих коллекциях, разными ролями.
        XCTAssertNotNil(bySegmentId[segmentIds[0]])
        XCTAssertNotNil(bySegmentId[segmentIds[1]])
        XCTAssertTrue(result.assignments.contains { $0.cluster == 0 })
        XCTAssertTrue(result.assignments.contains { $0.cluster == 1 })
    }
}
