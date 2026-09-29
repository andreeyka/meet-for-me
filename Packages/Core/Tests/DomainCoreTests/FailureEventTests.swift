//  FailureEventTests — К29 (инв. 24) перечня MEE-401 (C-016 v10): синхронный и асинхронный
//  пути ошибки дают на одном и том же входе один и тот же `code`; плюс проверка §3.1
//  «Три строки…», п. 2 — `AppFacadeError.underlying` кода не образует (К27, MEE-450).
//
//  Предмет теста — производственный код с обеих сторон, а не тестовая сторона: синхронный
//  `AppErrorView` строит команда фасада (`forgetVoiceProfile`, `openPermissionSettings`,
//  `beginConnectorAuth`) своим `wrap(_:)`, асинхронный — `AppFacadeImpl.publishFailure(_:)`,
//  получивший ту же исходную ошибку, и доставлен он настоящим `events()`. Тест сам не
//  строит ни одного `AppErrorView`, с которым потом сравнивает код (прежняя версия
//  `ErrorDictionaryTests` была возвращена РП именно за это — приёмка 10:15 UTC, находка 3).
//
//  Граница: места, из которых `publishFailure(_:)` вызывается в продакшене, контракт не
//  называет (см. заголовок `AppFacadeImpl+Failure.swift`) — здесь проверен механизм и
//  инв. 24 на нём, а не выбор триггеров.

import XCTest
@testable import DomainCore
import DomainTestKit

/// Общая фикстура `FailureEventTests` и `ErrorDictionaryEngineFacadeTests` — локальная,
/// без `SessionCoordinator`-фейка из `DomainTestKit` (страж K88): `NoOpSessionCoordinator`
/// этого же таргета.
struct FailureFixture {
    let facade: AppFacadeImpl
    let repositories: InMemoryRepositories
    let permissions: FakePermissionsPort
    let calendar: FakeCalendarPort

    init() {
        let repositories = InMemoryRepositories()
        let permissions = FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date())
        let calendar = FakeCalendarPort()
        self.repositories = repositories
        self.permissions = permissions
        self.calendar = calendar
        self.facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: permissions,
            modelCatalog: FakeModelCatalogPort(),
            calendar: calendar,
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            jobQueue: FakeJobQueue(),
            fileLayout: FileLayout(root: FileManager.default.temporaryDirectory),
            clock: { Date() }
        )
    }

    /// Асинхронный путь целиком: подписка на `events()` ДО публикации, затем
    /// `publishFailure(_:)`, затем первое событие потока — оно обязано быть `.failure`.
    func asyncView(for error: Error, file: StaticString = #filePath, line: UInt = #line) async -> AppErrorView? {
        let stream = facade.events()
        await facade.publishFailure(error)
        let events = await collectEvents(stream, count: 1)
        guard case .failure(let view)? = events.first else {
            XCTFail("ожидалось .failure, пришло \(events)", file: file, line: line)
            return nil
        }
        return view
    }
}

final class FailureEventTests: XCTestCase {

    private struct SyncVector {
        let name: String
        let error: Error
        let seed: (FailureFixture) -> Void
        let call: (AppFacadeImpl) async throws -> Void
    }

    private var vectors: [SyncVector] {
        let personId = UUID()
        let sourceId = CalendarSourceId(rawValue: "graph-work")
        return [
            SyncVector(
                name: "StorageError через forgetVoiceProfile",
                error: StorageError.io(message: "disk full"),
                seed: { $0.repositories.speakerProfiles.fail(
                    with: .io(message: "disk full"), on: .delete, id: personId.uuidString
                ) },
                call: { try await $0.forgetVoiceProfile(personId: personId) }
            ),
            SyncVector(
                name: "PermissionsError через openPermissionSettings",
                error: PermissionsError.settingsPaneUnavailable(kind: .microphone),
                seed: { $0.permissions.failOpenSettings(
                    with: .settingsPaneUnavailable(kind: .microphone), for: .microphone
                ) },
                call: { try await $0.openPermissionSettings(.microphone) }
            ),
            // Коннектор типа eventkit — у вектора непустой `permissionKind` (`.calendars`),
            // и сравнение идёт по обеим колонкам, а не только по `code`.
            SyncVector(
                name: "CalendarError.authorizationRequired (eventkit) через beginConnectorAuth",
                error: CalendarError.authorizationRequired(sourceId: sourceId),
                seed: { fixture in
                    fixture.repositories.connectors.seed([ConnectorRecord(
                        id: sourceId.rawValue, type: "eventkit", pluginId: nil, settingsJson: Data(),
                        keychainNamespace: sourceId.rawValue, selectedCalendarIds: [], isEnabled: true,
                        lastSyncAt: nil, cursor: nil, lastError: nil
                    )])
                    fixture.calendar.fail(
                        with: .authorizationRequired(sourceId: sourceId), on: .beginAuth, source: sourceId
                    )
                },
                call: { _ = try await $0.beginConnectorAuth(sourceId: sourceId) }
            )
        ]
    }

    /// К29 (инв. 24): одна и та же исходная ошибка — брошенная командой (синхронно,
    /// `AppFacadeError.underlying`) и опубликованная `publishFailure(_:)` (асинхронно,
    /// `AppEvent.failure`) — даёт один и тот же `code` и один и тот же `permissionKind`.
    func test_k29_syncAndAsyncDeliveryGiveSameCode() async throws {
        for vector in vectors {
            let fixture = FailureFixture()
            vector.seed(fixture)

            var syncView: AppErrorView?
            do {
                try await vector.call(fixture.facade)
                XCTFail("\(vector.name): ожидался отказ")
            } catch AppFacadeError.underlying(let view) {
                syncView = view
            }
            let asyncView = await fixture.asyncView(for: vector.error)

            XCTAssertNotNil(syncView, vector.name)
            XCTAssertEqual(asyncView?.code, syncView?.code, vector.name)
            XCTAssertEqual(asyncView?.permissionKind, syncView?.permissionKind, vector.name)
        }
    }

    /// §3.1, «Три строки…», п. 2: `AppFacadeError.underlying(AppErrorView)` кода не
    /// образует — вложенный `AppErrorView` выходит в `AppEvent.failure` без изменений, в
    /// том числе без префикса `facade.` и с тем же `permissionKind`.
    func test_k27_underlyingFormsNoCodeOfItsOwn() async throws {
        let inner = [
            AppErrorView(code: "storage.io", message: "m", recoverySuggestion: "r", permissionKind: nil),
            AppErrorView(
                code: "calendar.authorizationRequired", message: "m", recoverySuggestion: nil,
                permissionKind: .calendars
            ),
            AppErrorView(code: "engine.engineFailure.outOfMemory", message: "m", recoverySuggestion: nil,
                         permissionKind: nil),
            AppErrorView(code: "app.internalError", message: "m", recoverySuggestion: nil, permissionKind: nil)
        ]
        for view in inner {
            let fixture = FailureFixture()
            let published = await fixture.asyncView(for: AppFacadeError.underlying(view))
            XCTAssertEqual(published, view, view.code)
            XCTAssertEqual(AppFacadeError.underlying(view).view, view, view.code)
        }
    }

    private struct UnlistedError: Error, CustomStringConvertible {
        var description: String { "UnlistedError: ошибка вне словаря" }
    }

    /// Инв. 19 на асинхронном пути: тип без префикса §3.1 даёт `app.internalError`, и
    /// `message` содержит описание исходной ошибки (§3.1, строка «всё прочее»).
    func test_asyncPath_unlistedErrorGivesAppInternalError() async throws {
        let fixture = FailureFixture()
        let view = await fixture.asyncView(for: UnlistedError())
        XCTAssertEqual(view?.code, "app.internalError")
        XCTAssertNil(view?.permissionKind)
        XCTAssertTrue(view?.message.contains("ошибка вне словаря") ?? false, view?.message ?? "nil")
    }
}
