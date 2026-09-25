//  Оснастка IR-126 (MEE-385) — общая на MergeTests.swift и MergeCrossCycleTests.swift.
//
//  Вынесена из TestSupport.swift отдельным файлом (возврат РП, приёмка #128, «мелочь
//  К37»): TestSupport.swift сам перешагнул предел SwiftLint `file_length` (400 строк)
//  после добавления `assertNoChangeArrives` — тот же приём, что уже разводит другие пары
//  файлов модуля (`CalendarPortImplSync.swift`/`CalendarPortImplMerge.swift` и соседи):
//  SwiftLint считает КАЖДЫЙ файл отдельно, не суммой по модулю. Не `private static`
//  внутри одного класса теста (как было до возврата РП, приёмка #105) — та же причина.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен (оснастка тестов)

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import CalendarHub

/// Payload с общим `icalUid` ("shared-uid") — три источника с одним и тем же `icalUid`
/// сходятся на один дедуп-ключ (C-005 п. 4, признак (а)), не заводят три отдельных встречи.
/// `start`: по умолчанию фиксированная секунда — большинство вызывающих не варьируют её; К27
/// (`DedupAndMergeStepsTests.swift`) передаёт своё значение, чтобы попасть в ДРУГУЮ минуту
/// после округления инварианта 3 (`DedupKey.startEpochSeconds`), не меняя общий `icalUid`.
func mergeTestPayload(
    connectorId: String, externalId: String, lastModified: Date, location: String? = nil,
    attendees: [MeetingEvent.Attendee] = [], start: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> MeetingEventPayload {
    try MeetingEventPayload(
        sourceConnectorId: connectorId, externalId: externalId, icalUid: "shared-uid", title: "T",
        start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
        isCancelled: false, organizer: nil, attendees: attendees, location: location, bodyText: nil,
        conference: nil, lastModified: lastModified
    )
}

/// `responseStatus`: по умолчанию `.accepted`. К22 (`DedupAndMergeTests.swift`, возврат РП
/// 24.09 21:15 UTC) варьирует своим значением — раньше тест ошибочно варьировал `name`.
func mergeTestAttendee(
    name: String, email: String?, responseStatus: MeetingEvent.Attendee.ResponseStatus = .accepted
) throws -> MeetingEvent.Attendee {
    try MeetingEvent.Attendee(
        person: try MeetingEvent.Person(name: name, email: email), responseStatus: responseStatus, isOptional: false
    )
}

/// Счётчик вызовов `MeetingRepository.save(_:)` из общего `PortCallLog` фейка — инв. 11/К77
/// (`test_k77_secondMergeOfSameMeetingDoesNotStartUntilFirstFinishes`, MergeTests.swift)
/// опрашивает его напрямую, без ожидания конкретного тайминга самого слияния.
func meetingRepositorySaveCallCount(_ repository: InMemoryMeetingRepository) -> Int {
    repository.callLog.calls.filter { $0.signature == "MeetingRepository.save(_:)" }.count
}

/// Счётчик вызовов `ConnectorRepository.setSyncOutcome(at:error:connectorId:)` — бэклог
/// MEE-386, «часть 3г», п. 2 (`test_defect_staleGenerationDoesNotWriteSyncOutcome`,
/// `ControlSurfaceEntryPointsTests.swift`): без фикса устаревшее поколение писало бы СВОЙ
/// исход вторым вызовом — чистый счётчик отличает это от «записал только текущий», не
/// полагаясь на то, какое из двух значений в итоге осталось в хранилище (порядок между
/// независимыми continuation одной и той же цепочки `mergeTail` ничем не гарантирован).
func connectorRepositorySetSyncOutcomeCallCount(_ repository: InMemoryConnectorRepository) -> Int {
    let signature = "ConnectorRepository.setSyncOutcome(at:error:connectorId:)"
    return repository.callLog.calls.filter { $0.signature == signature }.count
}

/// Сеет мимо `save` встречу с двумя источниками ("A"/`evt-a`, "B"/`evt-b`, общий `icalUid`),
/// оба со снимками, identity и содержимое — B (больший `lastModified`) — общий пролог
/// `test_k80_sourceFailureInCycleKeepsOtherSourcesSnapshotsIntact` (MergeCrossCycleTests.swift),
/// вынесенный сюда той же причиной, что `mergeReady`: не раздувать тело теста сверх
/// `function_body_length`.
func seedTwoSourceMeetingIdentityB(
    _ harness: Harness, base: Date, locationA: String?, locationB: String?
) throws {
    let payloadA = try mergeTestPayload(connectorId: "A", externalId: "evt-a", lastModified: base, location: locationA)
    let payloadB = try mergeTestPayload(
        connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(1), location: locationB
    )
    let event = try MeetingEvent(
        id: UUID(), sourceConnectorId: "B", externalId: "evt-b", icalUid: "shared-uid", title: "T",
        start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false, isCancelled: false,
        organizer: nil, attendees: [], location: locationB, bodyText: nil, conference: nil,
        lastModified: base.addingTimeInterval(1)
    )
    let sources = [
        MeetingSource(
            sourceConnectorId: "A", externalId: "evt-a", icalUid: "shared-uid", lastModified: base, payload: payloadA
        ),
        MeetingSource(
            sourceConnectorId: "B", externalId: "evt-b", icalUid: "shared-uid",
            lastModified: base.addingTimeInterval(1), payload: payloadB
        )
    ]
    harness.meetingRepository.seed([
        MeetingRecord(event: event, dedupKey: DedupKey.make(from: event), status: .ready, sources: sources)
    ])
}

/// Сеет мимо `save` встречу с двумя источниками БЕЗ снимков (`MeetingSource.payload == nil`
/// у обоих) — `test_k65_inputV_...` (MergeTests.swift, К65 вход В), тот же довод, что у
/// `seedTwoSourceMeetingIdentityB` рядом.
func seedTwoSourceMeetingNoSnapshots(
    _ harness: Harness, eventId: UUID, base: Date
) throws {
    let event = try MeetingEvent(
        id: eventId, sourceConnectorId: "src-1", externalId: "evt-1", icalUid: nil, title: "Original",
        start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
        isCancelled: false, organizer: nil, attendees: [], location: nil, bodyText: nil,
        conference: nil, lastModified: base
    )
    let sources = [
        MeetingSource(sourceConnectorId: "src-1", externalId: "evt-1", icalUid: nil, lastModified: base),
        MeetingSource(
            sourceConnectorId: "src-2", externalId: "evt-2", icalUid: nil, lastModified: base.addingTimeInterval(60)
        )
    ]
    harness.meetingRepository.seed([MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: sources)])
}
