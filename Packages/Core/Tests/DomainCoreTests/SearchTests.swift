//  SearchTests — MEE-449: `AppFacadeImpl.search(query:limit:offset:)` (C-016 §4, `// C-010`) —
//  сквозная обёртка над `TranscriptRepository.search`, на `InMemoryTranscriptRepository`
//  (ФТР плана MEE-410), не `FakeAppFacade`.
//
//  Повторное чтение (инв. 3, К4) здесь не проверяется: К4 — предмет MEE-448.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class SearchTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
    }

    private func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: SearchTestSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors
        )
        return Fixture(facade: facade, repositories: repositories)
    }

    /// Аргументы доходят до репозитория без изменений, ответ репозитория — наружу без изменений.
    func test_search_passesArgumentsAndHitsThroughUnchanged() async throws {
        let fixture = makeFixture()
        _ = try await fixture.repositories.transcripts.save(TranscriptFixtures.oneOnOne)
        _ = try await fixture.repositories.transcripts.save(TranscriptFixtures.threeClustersOverlapping)
        let direct = try await fixture.repositories.transcripts.search(query: "а", limit: 3, offset: 1)
        let callsBefore = fixture.repositories.log.calls.count

        let hits = try await fixture.facade.search(query: "а", limit: 3, offset: 1)

        XCTAssertFalse(direct.isEmpty, "фикстура обязана дать совпадения, иначе равенство вакуумно")
        XCTAssertEqual(hits, direct)
        let searchCalls = fixture.repositories.log.calls.dropFirst(callsBefore)
            .filter { $0.method == "search(query:limit:offset:)" }
        XCTAssertEqual(searchCalls.count, 1)
        XCTAssertEqual(searchCalls.first?.arguments, ["а", "3", "1"])
    }

    /// Инв. 19, §3.1: отказ хранилища — `.underlying` с кодом `storage.<case>`, тип
    /// `StorageError` наружу не выходит.
    func test_search_storageFailureSurfacesAsUnderlyingStorageCode() async {
        let fixture = makeFixture()
        fixture.repositories.transcripts.fail(with: .io(message: "диск"), on: .search)

        do {
            _ = try await fixture.facade.search(query: "привет", limit: 10, offset: 0)
            XCTFail("отказ репозитория обязан дойти до вызывающего")
        } catch let error as AppFacadeError {
            guard case .underlying(let view) = error else {
                return XCTFail("ожидался .underlying, пришло \(error)")
            }
            XCTAssertEqual(view.code, "storage.io")
            XCTAssertNil(view.permissionKind)
        } catch {
            XCTFail("наружу вышел не AppFacadeError: \(error)")
        }
    }
}

/// Поиск координатора не касается; свой — по сторожу К88 (см. `RecordingCommandsTests.swift`).
private struct SearchTestSessionCoordinator: SessionCoordinator {
    func sessions() async -> [SessionSnapshot] { [] }
    func session(id: UUID) async -> SessionSnapshot? { nil }
    func prompts() async -> [SessionPrompt] { [] }
    func changes() -> AsyncStream<SessionChange> { AsyncStream { _ in } }
    func startRecording(meetingId: UUID?, now: Date) async throws -> UUID { UUID() }
    func stopRecording(recordingId: UUID, now: Date) async throws {}
    func skip(meetingId: UUID, now: Date) async throws {}
    func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws {}
    func start(now: Date) async {}
    func tick(now: Date) async {}
    func stop() async {}
}
