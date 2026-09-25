//  EventsTests — два вектора из возврата РП (приёмка 10:15 UTC): stopRecording (публикация
//  была, теста не было), ремонт нечитаемой строки настроек (находка 1). Разведено из
//  `EventsTests.swift` по объёму (`file_length`), не по смыслу — тот же приём, что
//  `EventsTests+PermissionsObservation.swift`. Общие `Fixture`/`makeFixture()`/
//  `collectEvents` — там же, не `private`.
//
//  editSegmentText → transcriptChanged (инв. 15) — НЕ здесь: требует новый метод
//  `TranscriptRepository` (резолвинг segmentId → transcriptId), которого нет в контракте
//  C-010 — см. докстринг `AppFacadeImpl.editSegmentText` в `AppFacadeImpl.swift`.

import XCTest
@testable import DomainCore
import DomainTestKit

extension EventsTests {

    // MARK: - stopRecording → statusChanged (возврат РП, «мелочи»: публикация есть, теста не было)

    func test_k33_stopRecording_publishesStatusChanged() async throws {
        let fixture = makeFixture()
        // Без подписки в этот момент — событие старта уходит в пустоту (нет подписчиков),
        // интересует только остановка.
        let recordingId = try await fixture.facade.startRecording(meetingId: nil)

        let stream = fixture.facade.events()
        try await fixture.facade.stopRecording(recordingId: recordingId)

        let events = await collectEvents(stream, count: 1)
        XCTAssertEqual(events.count, 1, "\(events)")
        guard case .statusChanged = events.first else {
            return XCTFail("ожидался .statusChanged, получено \(String(describing: events.first))")
        }
    }

    // MARK: - updateSettings — ремонт нечитаемой строки (возврат РП, находка 1)

    /// Раньше `previousReadiness` читался через `try await self.settings()` ВНУТРИ `do`, до
    /// цикла записи, — нечитаемая строка (`AppFacadeError.settingsUnreadable`) отказывала
    /// ЗДЕСЬ, раньше единственной попытки её же и починить (§2.1: запись — единственный путь
    /// исправить нечитаемое поле). Починка ключа `recordingPolicy` мусорными байтами мимо
    /// `DomainJSON` — сам вызов обязан пройти, а не отказать `settingsUnreadable`.
    func test_updateSettings_unreadableStoredField_stillSucceedsAndRepairsIt() async throws {
        let fixture = makeFixture()
        fixture.repositories.settings.seed(["recordingPolicy": Data("не json".utf8)])

        let stream = fixture.facade.events()
        let defaults = AppSettings.slice1Defaults
        try await fixture.facade.updateSettings(defaults)

        // `previousReadiness == nil` (строка не читалась) трактуется как «изменилось» —
        // statusChanged обязан уйти вместе с settingsChanged, даже когда права не менялись.
        let events = await collectEvents(stream, count: 2)
        XCTAssertEqual(events.count, 2, "\(events)")
        guard case .settingsChanged = events.first else {
            return XCTFail("первым ожидался .settingsChanged, получено \(String(describing: events.first))")
        }
        guard case .statusChanged = events.last else {
            return XCTFail("вторым ожидался .statusChanged, получено \(String(describing: events.last))")
        }

        let repaired = try await fixture.facade.settings()
        XCTAssertEqual(repaired.recordingPolicy, defaults.recordingPolicy, "строка обязана быть починена записью")
    }
}
