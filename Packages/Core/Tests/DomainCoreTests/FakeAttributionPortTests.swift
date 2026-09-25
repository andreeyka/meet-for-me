//  FakeAttributionPortTests — «Готовность» MEE-399: тесты на `DomainTestKit
//  .FakeAttributionPort` и `DomainTestKit.AttributionFixtures` (C-015 §«Фейк для тестов»).

import XCTest
import DomainCore
import DomainTestKit

final class FakeAttributionPortTests: XCTestCase {

    // MARK: - Фейк: считает вызовы с их аргументами, отдаёт заданный результат

    func test_fakeAttributionPortCountsAttributeCallsAndReturnsForcedResult() async throws {
        let port = FakeAttributionPort()
        let result = AttributionResult(
            transcriptId: UUID(), assignments: [], segmentUpdates: [], textCorrections: [], profileUpdates: []
        )
        port.forcedResult = result
        let input = AttributionFixtures.oneOnOneWithoutProfiles
        let thresholds = AttributionThresholds.slice1Defaults

        let returned = try await port.attribute(input, thresholds: thresholds)

        XCTAssertEqual(returned, result)
        XCTAssertEqual(port.attributeCallCount, 1)
        XCTAssertEqual(port.lastAttributedInput, input)
        XCTAssertEqual(port.lastAttributedThresholds, thresholds)
    }

    func test_fakeAttributionPortCountsConfirmCallsAndRecordsArguments() async throws {
        let port = FakeAttributionPort()
        port.forcedResult = AttributionResult(
            transcriptId: UUID(), assignments: [], segmentUpdates: [], textCorrections: [], profileUpdates: []
        )
        let input = AttributionFixtures.oneOnOneWithoutProfiles
        let transcriptId = UUID()
        let personId = UUID()

        _ = try await port.confirm(transcriptId: transcriptId, cluster: 0, personId: personId, input: input)

        XCTAssertEqual(port.confirmCallCount, 1)
        XCTAssertEqual(port.lastConfirmedTranscriptId, transcriptId)
        XCTAssertEqual(port.lastConfirmedCluster, 0)
        XCTAssertEqual(port.lastConfirmedPersonId, personId)
        XCTAssertEqual(port.lastConfirmedInput, input)
    }

    func test_fakeAttributionPortCountsRejectCallsAndRecordsArguments() async throws {
        let port = FakeAttributionPort()
        port.forcedResult = AttributionResult(
            transcriptId: UUID(), assignments: [], segmentUpdates: [], textCorrections: [], profileUpdates: []
        )
        let input = AttributionFixtures.oneOnOneWithoutProfiles
        let transcriptId = UUID()

        _ = try await port.reject(transcriptId: transcriptId, cluster: 1, input: input)

        XCTAssertEqual(port.rejectCallCount, 1)
        XCTAssertEqual(port.lastRejectedTranscriptId, transcriptId)
        XCTAssertEqual(port.lastRejectedCluster, 1)
        XCTAssertEqual(port.lastRejectedInput, input)
    }

    /// «Ошибку, которую бросит любой из трёх методов» — один переключатель, не три.
    func test_fakeAttributionPortThrowsForcedErrorFromAnyOfTheThreeMethods() async throws {
        let port = FakeAttributionPort()
        port.forcedError = .unknownCluster(7)
        let input = AttributionFixtures.oneOnOneWithoutProfiles

        do {
            _ = try await port.attribute(input, thresholds: .slice1Defaults)
            XCTFail("attribute должен бросить forcedError")
        } catch AttributionError.unknownCluster(let cluster) {
            XCTAssertEqual(cluster, 7)
        }

        do {
            _ = try await port.confirm(transcriptId: UUID(), cluster: 0, personId: UUID(), input: input)
            XCTFail("confirm должен бросить forcedError")
        } catch AttributionError.unknownCluster(let cluster) {
            XCTAssertEqual(cluster, 7)
        }

        do {
            _ = try await port.reject(transcriptId: UUID(), cluster: 0, input: input)
            XCTFail("reject должен бросить forcedError")
        } catch AttributionError.unknownCluster(let cluster) {
            XCTAssertEqual(cluster, 7)
        }
    }

    // MARK: - Режим «инв. 8» (MEE-420, приёмка `8328dd7c`) — средство для К52 плана MEE-410

    /// Выключен по умолчанию — старое поведение (форсированный результат отдаётся как есть).
    func test_fakeAttributionPortAppliesInvariant8DefaultsToOffAndReturnsForcedResultUnfiltered() async throws {
        let port = FakeAttributionPort()
        let update = SegmentAttributionUpdate(
            segmentId: 1, personId: UUID(), speakerConfidence: 0.9, attributionSource: .micChannel
        )
        port.forcedResult = AttributionResult(
            transcriptId: UUID(), assignments: [], segmentUpdates: [update], textCorrections: [], profileUpdates: []
        )
        let input = AttributionFixtures.oneOnOneWithoutProfiles

        let result = try await port.attribute(input, thresholds: .slice1Defaults)

        XCTAssertEqual(result.segmentUpdates, [update])
    }

    /// Включённый режим фильтрует `segmentUpdates` по ФАКТИЧЕСКОМУ `userEditedSegmentIds`
    /// вызова, а не по заранее заданной фикстуре — так К52 плана MEE-410 различает верный
    /// фасад (кластер исключён из входа, сегменты доходят) от фасада с багом К50 (кластер
    /// не исключён, фейк их отфильтровывает).
    func test_fakeAttributionPortAppliesInvariant8FiltersSegmentUpdatesByActualCallInput() async throws {
        let port = FakeAttributionPort()
        port.appliesInvariant8 = true
        let excludedUpdate = SegmentAttributionUpdate(
            segmentId: 1, personId: UUID(), speakerConfidence: 0.9, attributionSource: .micChannel
        )
        let keptUpdate = SegmentAttributionUpdate(
            segmentId: 2, personId: UUID(), speakerConfidence: 0.9, attributionSource: .micChannel
        )
        port.forcedResult = AttributionResult(
            transcriptId: UUID(), assignments: [], segmentUpdates: [excludedUpdate, keptUpdate],
            textCorrections: [], profileUpdates: []
        )
        let base = AttributionFixtures.oneOnOneWithoutProfiles
        let input = AttributionInput(
            transcriptId: base.transcriptId, transcript: base.transcript, segmentIds: base.segmentIds,
            meetingId: base.meetingId, attendees: base.attendees, me: base.me, nameForms: base.nameForms,
            profiles: base.profiles, voiceProfilesEnabled: base.voiceProfilesEnabled,
            embeddingModelVersion: base.embeddingModelVersion, userEditedSegmentIds: [1]
        )

        let result = try await port.confirm(transcriptId: UUID(), cluster: 0, personId: UUID(), input: input)

        XCTAssertEqual(result.segmentUpdates, [keptUpdate], "id 1 входит в userEditedSegmentIds вызова — отфильтрован")
    }

    // MARK: - Фикстуры: шесть именованных входов C-015 §«Фейк для тестов»

    func test_fixtureOneOnOneWithoutProfilesHasExactlyTwoAttendeesAndOneSystemCluster() {
        let input = AttributionFixtures.oneOnOneWithoutProfiles

        XCTAssertEqual(input.attendees.count, 2)
        XCTAssertNotNil(input.me)
        XCTAssertTrue(input.profiles.isEmpty, "без профилей — иначе сработало бы правило 2, не 3")
        XCTAssertEqual(input.transcript.speakers.count, 1, "ровно один системный кластер")
    }

    /// Разрыв между лучшим и вторым кандидатом строго меньше `profileMatchMargin` (0.05) —
    /// правило 2 обязано отказаться от назначения.
    func test_fixtureThreeParticipantsHasAmbiguousProfileMatchWithinMargin() throws {
        let input = AttributionFixtures.threeParticipantsAmbiguousProfileMatch
        let cluster = try XCTUnwrap(input.transcript.speakers.first?.embedding)

        let similarities = input.profiles
            .map { cosineSimilarity(cluster, $0.embedding) }
            .sorted(by: >)
        let best = try XCTUnwrap(similarities.first)
        let second = try XCTUnwrap(similarities.dropFirst().first)

        XCTAssertEqual(input.attendees.count, 4, "me + три участника")
        XCTAssertEqual(input.profiles.count, 3)
        XCTAssertLessThan(best - second, AttributionThresholds.slice1Defaults.profileMatchMargin)
    }

    func test_fixtureNoEmbeddingsHasNilEmbeddingForEverySpeaker() {
        let input = AttributionFixtures.noEmbeddings

        XCTAssertFalse(input.transcript.speakers.isEmpty)
        XCTAssertTrue(input.transcript.speakers.allSatisfy { $0.embedding == nil })
    }

    func test_fixtureUncertainWordNearParticipantNameHasLowConfidenceWordMatchingNameForm() throws {
        let input = AttributionFixtures.uncertainWordNearParticipantName
        let word = try XCTUnwrap(input.transcript.segments.first?.words.last)
        let nameForm = try XCTUnwrap(input.nameForms.first)

        let confidence = try XCTUnwrap(word.confidence)
        XCTAssertLessThan(confidence, AttributionThresholds.slice1Defaults.textConfidenceMax)
        XCTAssertEqual(nameForm.form, "Иван")
        XCTAssertTrue(word.text.contains("Ивам"), "правдоподобная ошибка ASR рядом с именем «Иван»")
    }

    /// Правка приёмки РП по PR #127: часть (в) инв. 21 говорит об исключении правленых строк
    /// по каналу безотносительно — фикстура несёт правленый и неправленый `.mic`-сегмент,
    /// не только системный, и тест сверяет канал каждого.
    func test_fixtureSegmentAlreadyUserEditedListsItsOwnSegmentId() throws {
        let input = AttributionFixtures.segmentAlreadyUserEdited

        XCTAssertEqual(input.segmentIds, [1, 2, 3])
        XCTAssertEqual(input.userEditedSegmentIds, [1, 2])

        let segments = input.transcript.segments
        XCTAssertEqual(segments[0].channel, .system, "id 1 — правленый системный")
        XCTAssertEqual(segments[1].channel, .mic, "id 2 — правленый микрофонный")
        XCTAssertEqual(segments[2].channel, .mic, "id 3 — неправленый микрофонный")
        XCTAssertFalse(input.userEditedSegmentIds.contains(3), "id 3 не правлен — единственный, кто должен уехать")
    }

    func test_fixtureSystemSegmentWhitespaceOnlyHasNilClusterAndBlankText() throws {
        let input = AttributionFixtures.whitespaceOnlySystemSegmentNoCluster
        let segment = try XCTUnwrap(input.transcript.segments.first)

        XCTAssertNil(segment.speakerCluster)
        XCTAssertTrue(segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(segment.channel, .system)
    }

    func test_allFixturesAreSixAndDistinct() {
        XCTAssertEqual(AttributionFixtures.allFixtures.count, 6)
        XCTAssertEqual(Set(AttributionFixtures.allFixtures.map(\.transcriptId)).count, 6, "шесть разных входов")
    }

    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let dot = zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let lhsNorm = (lhs.reduce(0.0) { $0 + Double($1) * Double($1) }).squareRoot()
        let rhsNorm = (rhs.reduce(0.0) { $0 + Double($1) * Double($1) }).squareRoot()
        return dot / (lhsNorm * rhsNorm)
    }
}
