//  EventsTests — К33, К34 перечня MEE-401 (C-016 v10), группа Л плана MEE-410. МЕЕ-437:
//  до этой задачи `AppEvent.statusChanged` нигде не публиковался (проверено `grep`'ом по
//  `.statusChanged(...)` в `Packages/Core/Sources/DomainCore` — см. `StatusMenu.swift`,
//  МЕЕ-433); публикация — предмет ЭТОЙ задачи, не только её тест.
//
//  Подписка ДО вызова команды — везде (постмортем MEE-377/378, `JobQueueEngineTestSupport.
//  swift`): опоздавшая подписка тихо теряет первое событие у broadcaster'а без буфера
//  (`AppEventBroadcaster.publish` рассылает только ЖИВЫМ на момент вызова подписчикам,
//  `AppFacadeImpl.swift`).
//
//  ШЕСТЬ ВЕКТОРОВ К33, ДОСТИЖИМЫХ В ЗОНЕ ЭТОЙ ЗАДАЧИ (`AppFacadeImpl*`, группы М–Х не
//  трогать) — ЧЕТЫРЕ ИЗ ШЕСТИ:
//   1. startRecording → statusChanged (и симметрично stopRecording).
//      — test_k33_startRecording_publishesStatusChanged, test_k33_stopRecording_publishesStatusChanged
//   2. updateSettings (поле вне permissionsReady) → settingsChanged, БЕЗ statusChanged.
//      — test_k33_updateSettings_unrelatedField_publishesOnlySettingsChanged
//   3. clearSpeaker → transcriptChanged(transcriptId:).    — test_k33_clearSpeaker_publishesTranscriptChanged
//   6. updateSettings, меняющий recordingPolicy так, что permissionsReady пересчитывается —
//      settingsChanged И statusChanged ОДНИМ вызовом (инв. 26).
//      — test_k33_updateSettings_policyChangingReadiness_publishesBothInOrder
//  ДВА ИЗ ШЕСТИ — ВНЕ ЗОНЫ: (4) downloadModel/deleteModel → modelsChanged — методы группы Н
//  (`AppFacadeImpl+Reads.swift` и соседи, не реализованы, бросают `notImplemented`, владеет
//  DEV-2 после MEE-431/MEE-420) — не публикуют ничего, потому что не существуют телом.
//  (5) setConnectorEnabled → meetingsChanged — метод группы О, тот же статус; ЗАМЕНА,
//  дословно допустимая перечнем («или успешная syncCalendars») —
//  test_k33_syncCalendars_publishesMeetingsChangedAndStatusChanged — уже реализованный, в
//  зоне этой задачи метод, публикующий то же событие.
//
//  Возврат РП (приёмка 10:15 UTC, находка 4): «Поведение» требует `.statusChanged` везде,
//  где меняется статус, — не только у команд фасада. Смена права ДРУГИМ путём (системные
//  настройки, мимо любого вызова фасада) тоже меняет `permissionsReady` — фасад подписан на
//  `PermissionsPort.changes()` (см. `AppFacadeImpl+PermissionsObservation.swift`) и публикует
//  `.permissionsChanged` + `.statusChanged`, если готовность действительно поменялась —
//  test_permissionsPortChange_publishesPermissionsChangedAndStatusChangedWhenReadinessDiffers,
//  test_permissionsPortChange_readinessUnaffected_publishesOnlyPermissionsChanged.

import XCTest
@testable import DomainCore
import DomainTestKit

/// Общий сборщик для этого файла и `PermissionsReadyTests.swift`/`ErrorDictionaryTests.swift`
/// (тот же тестовый таргет `DomainCoreTests`) — та же гонка `next()`-с-таймаутом, что уже
/// проверена и задокументирована `JobQueueEngineTestSupport.nextOrFail` (МЕЕ-377/378): голые
/// `Task`, не `TaskGroup` (`withTaskGroup` на выходе сам ждёт каждую дочернюю задачу до
/// конца — тот же довод, что у `nextOrFail`), копия `iterator` в своей `Task` читает из того
/// же общего буфера потока, обе проигравшие задачи `cancel()`ятся в `defer`. Не переиспользует
/// сам `nextOrFail` дословно — та функция типизирована на `AsyncStream<JobEvent>`, не
/// `AsyncStream<AppEvent>`, а `DrainRaceOutcome` там `private` своему файлу.
/// Простой (не вложенно-опциональный, в отличие от `DrainRaceOutcome`) исход гонки —
/// `.event(nil)` (поток кончился — на практике не случается, см. докстринг
/// `AppFacadeImpl.events()`) и `.timedOut` (таймаут) должны остаться РАЗЛИЧИМЫ, что
/// вложенный `T??`-приём у `DrainRaceOutcome` даёт только при аккуратном обращении с
/// `.none`/`.some(nil)`; отдельный `enum` здесь исключает этот источник ошибки, а не
/// экономит код.
private enum EventRaceOutcome {
    case event(AppEvent?)
    case timedOut
}

private actor AppEventRaceOutcome {
    private var value: EventRaceOutcome?
    private var waiters: [CheckedContinuation<EventRaceOutcome, Never>] = []

    func resolve(_ newValue: EventRaceOutcome) {
        guard value == nil else { return }
        value = newValue
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume(returning: newValue)
        }
    }

    func wait() async -> EventRaceOutcome {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// `nil` — ни одного события не пришло за окно (ожидаемый исход у «событий больше нет»
/// векторов, не провал теста самим по себе — в отличие от `nextOrFail`, этот вариант не
/// `XCTFail`'ит на таймауте, вызывающая сторона решает сама).
private func nextEventOrNil(
    _ iterator: AsyncStream<AppEvent>.AsyncIterator, seconds: UInt64
) async -> AppEvent? {
    let outcome = AppEventRaceOutcome()
    let racer = Task {
        var iterator = iterator
        let event = await iterator.next()
        await outcome.resolve(.event(event))
    }
    let timeoutTask = Task {
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        await outcome.resolve(.timedOut)
    }
    defer {
        racer.cancel()
        timeoutTask.cancel()
    }
    switch await outcome.wait() {
    case .event(let event): return event
    case .timedOut: return nil
    }
}

func collectEvents(_ stream: AsyncStream<AppEvent>, count: Int, timeoutSeconds: UInt64 = 5) async -> [AppEvent] {
    let iterator = stream.makeAsyncIterator()
    var collected: [AppEvent] = []
    for _ in 0..<count {
        guard let event = await nextEventOrNil(iterator, seconds: timeoutSeconds) else { break }
        collected.append(event)
    }
    return collected
}

final class EventsTests: XCTestCase {

    /// Не `private` — companion-файл `EventsTests+PermissionsObservation.swift` (тот же
    /// таргет, разведён по объёму, не по смыслу) пользуется той же фикстурой, тем же приёмом,
    /// что `SpeakerAssignmentTests`/`SpeakerAssignmentTests+DeltaShch.swift`.
    struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let attribution: FakeAttributionPort
        let permissions: FakePermissionsPort
    }

    func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
        let attribution = FakeAttributionPort()
        let permissions = FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date())
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: permissions,
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: attribution,
            settings: repositories.settings,
            clock: { Date() }
        )
        return Fixture(facade: facade, repositories: repositories, attribution: attribution, permissions: permissions)
    }

    // MARK: - К33, вектор 1: startRecording → statusChanged

    func test_k33_startRecording_publishesStatusChanged() async throws {
        let fixture = makeFixture()
        let stream = fixture.facade.events()
        _ = try await fixture.facade.startRecording(meetingId: nil)

        let events = await collectEvents(stream, count: 1)
        XCTAssertEqual(events.count, 1)
        guard case .statusChanged = events.first else {
            return XCTFail("ожидался .statusChanged, получено \(String(describing: events.first))")
        }
    }

    // MARK: - К33, вектор 2: updateSettings без влияния на permissionsReady → только settingsChanged

    func test_k33_updateSettings_unrelatedField_publishesOnlySettingsChanged() async throws {
        let fixture = makeFixture()
        let stream = fixture.facade.events()
        let defaults = AppSettings.slice1Defaults
        let changed = AppSettings(
            recordingPolicy: defaults.recordingPolicy, armLeadSeconds: 999, askLeadSeconds: defaults.askLeadSeconds,
            missingSignalGraceSeconds: defaults.missingSignalGraceSeconds,
            silenceStopSeconds: defaults.silenceStopSeconds, defaultProfileId: defaults.defaultProfileId,
            processOnACPowerOnly: defaults.processOnACPowerOnly, processWhileRecording: defaults.processWhileRecording,
            audioRetentionDays: defaults.audioRetentionDays, voiceProfilesEnabled: defaults.voiceProfilesEnabled,
            notifyParticipants: defaults.notifyParticipants, launchAtLogin: defaults.launchAtLogin
        )
        try await fixture.facade.updateSettings(changed)

        // Два события с коротким таймаутом: если бы statusChanged всё же ушёл (регрессия),
        // он оказался бы вторым — collectEvents(count: 2) поймал бы его в отведённое время.
        let events = await collectEvents(stream, count: 2, timeoutSeconds: 1)
        XCTAssertEqual(events.count, 1, "\(events)")
        guard case .settingsChanged(let published) = events.first else {
            return XCTFail("ожидался .settingsChanged, получено \(String(describing: events.first))")
        }
        XCTAssertEqual(published, changed)
    }

    // MARK: - К33, вектор 3: clearSpeaker → transcriptChanged(transcriptId:)

    func test_k33_clearSpeaker_publishesTranscriptChanged() async throws {
        let fixture = makeFixture()
        let word = try Transcript.Word(startMs: 0, endMs: 800, text: "слово", confidence: nil, original: nil)
        let segment = try Transcript.Segment(
            startMs: 0, endMs: 800, channel: .system, speakerCluster: 0,
            text: "текст", textOriginal: nil, textConfidence: nil, words: [word]
        )
        let speaker = try Transcript.Speaker(
            cluster: 0, embedding: [0.1, 0.2], embeddingModelVersion: "v1", totalMs: 800
        )
        let transcript = try Transcript(
            recordingId: UUID(), language: "ru", engine: "engine", modelVersion: "1.0",
            createdAt: Date(timeIntervalSince1970: 0), segments: [segment], speakers: [speaker]
        )
        let header = try await fixture.repositories.transcripts.save(transcript)
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: header.id, assignments: [], segmentUpdates: [], textCorrections: [], profileUpdates: []
        )

        let stream = fixture.facade.events()
        try await fixture.facade.clearSpeaker(transcriptId: header.id, cluster: 0)

        let events = await collectEvents(stream, count: 1)
        XCTAssertEqual(events.count, 1)
        guard case .transcriptChanged(let transcriptId) = events.first else {
            return XCTFail("ожидался .transcriptChanged, получено \(String(describing: events.first))")
        }
        XCTAssertEqual(transcriptId, header.id)
    }

    // MARK: - К33, заместитель вектора 5 (`setConnectorEnabled` вне зоны): syncCalendars → meetingsChanged

    /// Возврат РП (приёмка 10:15 UTC, находка 4): `syncCalendars` теперь публикует ДВА
    /// события одним вызовом — `.meetingsChanged` (список встреч) и `.statusChanged`
    /// (`AppStatus.upcoming` строится из тех же встреч) — в этом порядке.
    func test_k33_syncCalendars_publishesMeetingsChangedAndStatusChanged() async {
        let fixture = makeFixture()
        let stream = fixture.facade.events()
        _ = await fixture.facade.syncCalendars()

        let events = await collectEvents(stream, count: 2)
        XCTAssertEqual(events.count, 2, "\(events)")
        guard case .meetingsChanged = events.first else {
            return XCTFail("первым ожидался .meetingsChanged, получено \(String(describing: events.first))")
        }
        guard case .statusChanged = events.last else {
            return XCTFail("вторым ожидался .statusChanged, получено \(String(describing: events.last))")
        }
    }

    // MARK: - К33, вектор 6 (инв. 26, возврат РП п.7): settingsChanged И statusChanged одним вызовом

    /// Возврат РП (приёмка 10:15 UTC, находка 2): значение ВНУТРИ `.statusChanged` тоже
    /// проверяется здесь (`.ready`, а не только сам факт «пришёл случай .statusChanged») —
    /// раньше проверялся только вид события, и подделка «`.statusChanged` всегда несёт
    /// `.notReady`» проходила бы. Детальные ступени (`.notReady`/`.unknownUntilFirstUse`/
    /// `.ready`) самого расчёта — предмет `PermissionsReadyTests.test_k32_vectorD_...`; здесь
    /// — что ОБА события уходят одним вызовом `updateSettings`, в этом порядке (settingsChanged
    /// публикуется первым по тексту метода, до сравнения готовности — см.
    /// `AppFacadeImpl+Settings.swift`), и что значение внутри второго отражает переход.
    func test_k33_updateSettings_policyChangingReadiness_publishesBothInOrder() async throws {
        // Своя фикстура, не `makeFixture()`: readiness-сравнение (инв. 26) требует явно
        // заданного блокирующего состояния `.notifications`, а не общего `startingStatus:
        // .granted`, которым пользуются остальные тесты этого файла.
        let repositories = InMemoryRepositories()
        let permissions = FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date())
        permissions.setStatus(.denied, for: .notifications)
        let facade = AppFacadeImpl(
            meetings: repositories.meetings, recordings: repositories.recordings,
            transcripts: repositories.transcripts, persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles, permissions: permissions,
            modelCatalog: FakeModelCatalogPort(), calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(), attribution: FakeAttributionPort(),
            settings: repositories.settings, clock: { Date() }
        )
        // Исходно (slice1Defaults.recordingPolicy == .ask) notifications уже обязательно и
        // denied — permissionsReady стартует .notReady. Переход в .auto делает его не
        // обязательным — готовность меняется, и по инв. 26 statusChanged обязан уйти вместе
        // с settingsChanged.
        let defaults = AppSettings.slice1Defaults
        let changed = AppSettings(
            recordingPolicy: .auto, armLeadSeconds: defaults.armLeadSeconds, askLeadSeconds: defaults.askLeadSeconds,
            missingSignalGraceSeconds: defaults.missingSignalGraceSeconds,
            silenceStopSeconds: defaults.silenceStopSeconds, defaultProfileId: defaults.defaultProfileId,
            processOnACPowerOnly: defaults.processOnACPowerOnly, processWhileRecording: defaults.processWhileRecording,
            audioRetentionDays: defaults.audioRetentionDays, voiceProfilesEnabled: defaults.voiceProfilesEnabled,
            notifyParticipants: defaults.notifyParticipants, launchAtLogin: defaults.launchAtLogin
        )

        let stream = facade.events()
        try await facade.updateSettings(changed)

        let events = await collectEvents(stream, count: 2)
        XCTAssertEqual(events.count, 2, "\(events)")
        guard case .settingsChanged = events.first else {
            return XCTFail("первым ожидался .settingsChanged, получено \(String(describing: events.first))")
        }
        guard case .statusChanged(let status) = events.last else {
            return XCTFail("вторым ожидался .statusChanged, получено \(String(describing: events.last))")
        }
        XCTAssertEqual(
            status.permissionsReady, .ready, "переход .notReady → .ready — .auto больше не требует notifications"
        )
    }

    // MARK: - К34 (инв. 16): два независимых подписчика, подписка после уже произошедшего события

    /// Возврат РП (приёмка 10:15 UTC, «мелочи»; повторная приёмка 11:05 UTC, находка 2):
    /// событие ДО подписки и событие ПОСЛЕ — разных видов, и оба — ОДНОГО события каждое,
    /// не только «разных по имени первого случая». Первая редакция брала `syncCalendars` до
    /// подписки — тогда ЕГО ПОСЛЕДНИМ событием тоже был `.statusChanged` (К33, находка 4),
    /// того же вида, что и `startRecording` после подписки, — подделка «новому подписчику
    /// повторяется последнее событие» дала бы `.statusChanged` и в этом случае тоже, и тест
    /// её не поймал бы. `clearSpeaker` до подписки публикует РОВНО ОДНО событие,
    /// `.transcriptChanged`, — гарантированно другого вида, чем `.statusChanged` после.
    func test_k34_twoSubscribers_missEventBeforeSubscription_thenSeeSameSequence() async throws {
        let fixture = makeFixture()
        let word = try Transcript.Word(startMs: 0, endMs: 800, text: "слово", confidence: nil, original: nil)
        let segment = try Transcript.Segment(
            startMs: 0, endMs: 800, channel: .system, speakerCluster: 0,
            text: "текст", textOriginal: nil, textConfidence: nil, words: [word]
        )
        let speaker = try Transcript.Speaker(
            cluster: 0, embedding: [0.1, 0.2], embeddingModelVersion: "v1", totalMs: 800
        )
        let transcript = try Transcript(
            recordingId: UUID(), language: "ru", engine: "engine", modelVersion: "1.0",
            createdAt: Date(timeIntervalSince1970: 0), segments: [segment], speakers: [speaker]
        )
        let header = try await fixture.repositories.transcripts.save(transcript)
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: header.id, assignments: [], segmentUpdates: [], textCorrections: [], profileUpdates: []
        )

        // До подписки — ни одному будущему подписчику не достанется (не буферизуется).
        // clearSpeaker публикует ровно одно .transcriptChanged.
        try await fixture.facade.clearSpeaker(transcriptId: header.id, cluster: 0)

        let streamA = fixture.facade.events()
        let streamB = fixture.facade.events()
        _ = try await fixture.facade.startRecording(meetingId: nil)

        async let eventsA = collectEvents(streamA, count: 1)
        async let eventsB = collectEvents(streamB, count: 1)
        let (resultA, resultB) = await (eventsA, eventsB)

        XCTAssertEqual(resultA.count, 1, "подписчик A: \(resultA)")
        XCTAssertEqual(resultB.count, 1, "подписчик B: \(resultB)")
        guard case .statusChanged = resultA.first, case .statusChanged = resultB.first else {
            return XCTFail(
                "оба подписчика ожидали ровно .statusChanged (не .transcriptChanged до подписки): " +
                "A=\(resultA) B=\(resultB)"
            )
        }
    }
}
