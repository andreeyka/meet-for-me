//  SpeakerAssignmentTests — К50-К52 (дельта Щ перечня MEE-401). Разведено из
//  `SpeakerAssignmentTests.swift` по объёму (`file_length`/`type_body_length`), не по смыслу —
//  тот же класс, `Fixture`/`makeFixture()`/`resultWithOneUpdate()`/`segmentRows()` оттуда не
//  `private` специально ради этого файла.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

extension SpeakerAssignmentTests {

    // MARK: - К50 (дельта Щ): сегменты назначаемого кластера исключены из userEditedSegmentIds,
    // а уже помеченный сегмент ЧУЖОГО кластера остаётся — иначе тест прошёл бы и у реализации,
    // всегда возвращающей пустой userEditedSegmentIds. Три входа: confirm (assignSpeaker),
    // reject (clearSpeaker), confirm с новым personId (createPersonAndAssign).

    func test_k50_assignSpeakerExcludesTargetClusterKeepsForeignCluster() async throws {
        let fixture = try await makeFixture()
        let targetSegmentId = fixture.clusterASegmentIds[0]
        let foreignSegmentId = fixture.clusterBSegmentIds[0]
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: targetSegmentId, text: "уже правлено (кластер вызова)", isUserEdited: true
        )
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: foreignSegmentId, text: "уже правлено (чужой кластер)", isUserEdited: true
        )
        fixture.attribution.forcedResult = resultWithOneUpdate(
            transcriptId: fixture.transcriptId, segmentId: targetSegmentId
        )

        try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: UUID())

        let input = try XCTUnwrap(fixture.attribution.lastConfirmedInput)
        XCTAssertFalse(
            input.userEditedSegmentIds.contains(targetSegmentId),
            "сегмент назначаемого кластера обязан быть исключён, даже уже помеченный"
        )
        XCTAssertTrue(
            input.userEditedSegmentIds.contains(foreignSegmentId),
            "сегмент чужого кластера обязан остаться в userEditedSegmentIds"
        )
    }

    func test_k50_clearSpeakerExcludesTargetClusterKeepsForeignCluster() async throws {
        let fixture = try await makeFixture()
        let targetSegmentId = fixture.clusterASegmentIds[0]
        let foreignSegmentId = fixture.clusterBSegmentIds[0]
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: targetSegmentId, text: "уже правлено (кластер вызова)", isUserEdited: true
        )
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: foreignSegmentId, text: "уже правлено (чужой кластер)", isUserEdited: true
        )
        fixture.attribution.forcedResult = resultWithOneUpdate(
            transcriptId: fixture.transcriptId, segmentId: targetSegmentId
        )

        try await fixture.facade.clearSpeaker(transcriptId: fixture.transcriptId, cluster: 0)

        let input = try XCTUnwrap(fixture.attribution.lastRejectedInput)
        XCTAssertFalse(
            input.userEditedSegmentIds.contains(targetSegmentId),
            "сегмент снимаемого кластера обязан быть исключён, даже уже помеченный"
        )
        XCTAssertTrue(
            input.userEditedSegmentIds.contains(foreignSegmentId),
            "сегмент чужого кластера обязан остаться в userEditedSegmentIds"
        )
    }

    func test_k50_createPersonAndAssignExcludesTargetClusterKeepsForeignCluster() async throws {
        let fixture = try await makeFixture()
        let targetSegmentId = fixture.clusterASegmentIds[0]
        let foreignSegmentId = fixture.clusterBSegmentIds[0]
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: targetSegmentId, text: "уже правлено (кластер вызова)", isUserEdited: true
        )
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: foreignSegmentId, text: "уже правлено (чужой кластер)", isUserEdited: true
        )
        fixture.attribution.forcedResult = resultWithOneUpdate(
            transcriptId: fixture.transcriptId, segmentId: targetSegmentId
        )

        _ = try await fixture.facade.createPersonAndAssign(
            transcriptId: fixture.transcriptId, cluster: 0, displayName: "Новый Спикер", email: nil
        )

        let input = try XCTUnwrap(fixture.attribution.lastConfirmedInput)
        XCTAssertFalse(
            input.userEditedSegmentIds.contains(targetSegmentId),
            "сегмент назначаемого кластера обязан быть исключён, даже уже помеченный"
        )
        XCTAssertTrue(
            input.userEditedSegmentIds.contains(foreignSegmentId),
            "сегмент чужого кластера обязан остаться в userEditedSegmentIds"
        )
    }

    // MARK: - К51 (дельта Щ): segmentUpdates вперемешку несёт кластер вызова и чужой кластер —
    // разметка идёт по кластеру вызова (минимум два сегмента), а не по составу segmentUpdates

    func test_k51_markingCoversOnlyTargetClusterNotOther() async throws {
        let fixture = try await makeFixture()
        let personId = UUID()
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: fixture.transcriptId, assignments: [],
            segmentUpdates: [
                SegmentAttributionUpdate(
                    segmentId: fixture.clusterASegmentIds[0], personId: personId, speakerConfidence: 0.9,
                    attributionSource: .user
                ),
                SegmentAttributionUpdate(
                    segmentId: fixture.clusterBSegmentIds[0], personId: UUID(), speakerConfidence: 0.5,
                    attributionSource: .oneOnOne
                )
            ],
            textCorrections: [], profileUpdates: []
        )

        try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: personId)

        let rows = try await segmentRows(fixture)
        for segmentId in fixture.clusterASegmentIds {
            let row = try XCTUnwrap(rows.first { $0.id == segmentId })
            XCTAssertTrue(row.isUserEdited, "сегмент \(segmentId) кластера 0 обязан быть помечен")
        }
        for segmentId in fixture.clusterBSegmentIds {
            let row = try XCTUnwrap(rows.first { $0.id == segmentId })
            XCTAssertFalse(
                row.isUserEdited,
                "сегмент \(segmentId) чужого кластера 1 не должен быть помечен, даже попав в segmentUpdates"
            )
        }
    }

    // MARK: - К52 (дельта Щ, C-010 инв. 17): повторное ручное назначение того же кластера не
    // теряется — ни когда сегмент помечен предыдущим вызовом самого фасада (а), ни когда
    // помечен вручную мимо фасада (б)

    /// Вектор (а): кластер помечен предыдущим `assignSpeaker` фасада (не прямой правкой
    /// репозитория) — повторное назначение с новым `personId` обязано применяться.
    func test_k52_reassigningClusterMarkedByPriorFacadeCallStillAppliesUpdate() async throws {
        let fixture = try await makeFixture()
        let segmentId = fixture.clusterASegmentIds[0]
        let firstPersonId = UUID()
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: fixture.transcriptId, assignments: [],
            segmentUpdates: [SegmentAttributionUpdate(
                segmentId: segmentId, personId: firstPersonId, speakerConfidence: 0.9, attributionSource: .user
            )],
            textCorrections: [], profileUpdates: []
        )
        try await fixture.facade.assignSpeaker(
            transcriptId: fixture.transcriptId, cluster: 0, personId: firstPersonId
        )

        fixture.attribution.appliesInvariant8 = true
        let secondPersonId = UUID()
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: fixture.transcriptId, assignments: [],
            segmentUpdates: [SegmentAttributionUpdate(
                segmentId: segmentId, personId: secondPersonId, speakerConfidence: 0.95, attributionSource: .user
            )],
            textCorrections: [], profileUpdates: []
        )

        try await fixture.facade.assignSpeaker(
            transcriptId: fixture.transcriptId, cluster: 0, personId: secondPersonId
        )

        let rows = try await segmentRows(fixture)
        let row = try XCTUnwrap(rows.first { $0.id == segmentId })
        XCTAssertEqual(row.personId, secondPersonId, "второе назначение обязано применить новый personId")
        XCTAssertTrue(row.isUserEdited)
    }

    /// Вектор (б): сегмент помечен напрямую (мимо фасада) до первого вызова `assignSpeaker`.
    func test_k52_reassigningClusterEditedManuallyStillAppliesUpdate() async throws {
        let fixture = try await makeFixture()
        let segmentId = fixture.clusterASegmentIds[0]
        try await fixture.repositories.transcripts.updateSegmentText(
            segmentId: segmentId, text: "первая правка", isUserEdited: true
        )
        fixture.attribution.appliesInvariant8 = true
        let personId = UUID()
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: fixture.transcriptId,
            assignments: [],
            segmentUpdates: [SegmentAttributionUpdate(
                segmentId: segmentId, personId: personId, speakerConfidence: 0.95, attributionSource: .user
            )],
            textCorrections: [], profileUpdates: []
        )

        try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: personId)

        // Если бы К50 не исключил сегмент из userEditedSegmentIds, честный порт (appliesInvariant8)
        // отфильтровал бы это обновление сам, и updateAttribution не увидел бы ни одной строки.
        XCTAssertEqual(
            fixture.repositories.log.count(port: "TranscriptRepository", method: "updateAttribution(_:)"), 1
        )
        let rows = try await segmentRows(fixture)
        let row = try XCTUnwrap(rows.first { $0.id == segmentId })
        XCTAssertEqual(row.personId, personId)
        XCTAssertTrue(row.isUserEdited)
    }
}
