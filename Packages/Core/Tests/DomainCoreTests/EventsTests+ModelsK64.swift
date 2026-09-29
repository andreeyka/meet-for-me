//  К64 перечня MEE-401 (дельта АВ, f89d2865): C-016 v11 инв. 15 с уточнением IR-144 —
//  `modelsChanged` покрывает каталог C-014 целиком (модели и профили); `downloadModel`,
//  отказавшая после смены состояния модели, публикует его до броска; отказы `deleteModel` и
//  команд профилей событий не публикуют. Задача MEE-465.
//
//  «Не публикуется ни одного события» наблюдается контрольным событием: после отказа тест
//  вызывает `updateSettings` и первым в потоке ждёт `settingsChanged`.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

/// Каталог, у которого `download` сначала меняет состояние модели (`error`), затем бросает —
/// вектор (iii) К64. Прочее — к `FakeModelCatalogPort` без изменений.
private final class StateChangingDownloadFailureCatalog: ModelCatalogPort, @unchecked Sendable {
    let inner: FakeModelCatalogPort
    let failure: ModelCatalogError

    init(inner: FakeModelCatalogPort, failure: ModelCatalogError) {
        self.inner = inner
        self.failure = failure
    }

    func download(id: String, version: String) async throws {
        inner.setState(.error(failure), forId: id, version: version)
        throw failure
    }

    func refreshCatalog() async throws { try await inner.refreshCatalog() }
    func models() async -> [ModelDescriptor] { await inner.models() }
    func model(id: String, version: String) async -> ModelDescriptor? { await inner.model(id: id, version: version) }
    func state(id: String, version: String) async -> ModelState { await inner.state(id: id, version: version) }
    func cancelDownload(id: String, version: String) async { await inner.cancelDownload(id: id, version: version) }
    func verify(id: String, version: String) async throws { try await inner.verify(id: id, version: version) }
    func delete(id: String, version: String) async throws { try await inner.delete(id: id, version: version) }
    func diskUsage() async -> [ModelDiskUsage] { await inner.diskUsage() }
    func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken { try await inner.beginUse(bundles) }
    func endUse(_ token: ModelUseToken) async { await inner.endUse(token) }
    func profiles() async -> [TranscriptionProfile] { await inner.profiles() }
    func saveProfile(_ profile: TranscriptionProfile) async throws { try await inner.saveProfile(profile) }
    func deleteProfile(id: String) async throws { try await inner.deleteProfile(id: id) }
    func resolve(profileId: String) async throws -> ResolvedProfile { try await inner.resolve(profileId: profileId) }
    func missingModels(profileId: String) async throws -> [ModelDescriptor] {
        try await inner.missingModels(profileId: profileId)
    }
    func events() -> AsyncStream<ModelCatalogEvent> { inner.events() }
}

extension EventsTests {

    /// Векторы (i), (ii): успешные `saveProfile`/`deleteProfile` публикуют `modelsChanged`.
    func test_k64_saveAndDeleteProfilePublishModelsChanged() async throws {
        let fixture = ModelJobFixture()
        fixture.catalog.setCatalog([ModelJobFixture.descriptor("m-asr", role: .asr)])
        let profile = ModelJobFixture.profile("user-1", asr: "m-asr")

        let saveStream = fixture.facade.events()
        try await fixture.facade.saveProfile(profile)
        let afterSave = await collectEvents(saveStream, count: 1)
        XCTAssertEqual(afterSave, [.modelsChanged], "(i) saveProfile — до возврата")

        let deleteStream = fixture.facade.events()
        try await fixture.facade.deleteProfile(id: profile.id)
        let afterDelete = await collectEvents(deleteStream, count: 1)
        XCTAssertEqual(afterDelete, [.modelsChanged], "(ii) deleteProfile — до возврата")
    }

    /// Вектор (iii): `download` сменил состояние модели и бросил — `modelsChanged` до броска,
    /// сама команда бросает `underlying` с кодом `models.*`.
    func test_k64_downloadModelFailureAfterStateChangePublishesModelsChangedBeforeThrow() async throws {
        let repositories = InMemoryRepositories()
        let inner = FakeModelCatalogPort()
        inner.setCatalog([ModelJobFixture.descriptor("m1", role: .asr)])
        let failure = ModelCatalogError.downloadFailed(message: "network")
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: StateChangingDownloadFailureCatalog(inner: inner, failure: failure),
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            jobQueue: FakeJobQueue(),
            clock: { Date() }
        )
        let stream = facade.events()
        let view = await underlyingView { try await facade.downloadModel(id: "m1", version: "1.0.0") }
        XCTAssertEqual(view?.code, "models.downloadFailed")
        let stateAfter = await inner.state(id: "m1", version: "1.0.0")
        XCTAssertEqual(stateAfter, .error(failure), "оснастка: состояние модели сменилось")
        let events = await collectEvents(stream, count: 1)
        XCTAssertEqual(events, [.modelsChanged], "(iii) событие опубликовано до броска")
    }

    /// Векторы (iv), (v): отказ без изменений — `deleteModel` на занятой модели, `saveProfile`
    /// на встроенном профиле — не публикует ни одного события.
    func test_k64_deleteModelAndProfileRefusalsPublishNothing() async throws {
        let fixture = ModelJobFixture()
        fixture.catalog.setCatalog([ModelJobFixture.descriptor("m-asr", role: .asr)])
        fixture.catalog.setState(.downloaded, forId: "m-asr", version: "1.0.0")
        let builtIn = ModelJobFixture.profile("builtin", asr: "m-asr", builtIn: true)
        fixture.catalog.setProfiles([builtIn])
        fixture.catalog.failDelete(.modelInUseByProfile(modelId: "m-asr", profileIds: ["builtin"]),
                                   forId: "m-asr", version: "1.0.0")
        fixture.catalog.failProfileCommand(.builtInProfileImmutable(id: "builtin"), forProfileId: "builtin")

        let stream = fixture.facade.events()
        let deleteView = await underlyingView { try await fixture.facade.deleteModel(id: "m-asr", version: "1.0.0") }
        XCTAssertEqual(deleteView?.code, "models.modelInUseByProfile", "(iv)")
        let stateAfter = await fixture.catalog.state(id: "m-asr", version: "1.0.0")
        XCTAssertEqual(stateAfter, .downloaded, "(iv) состояние не изменилось")
        let saveView = await underlyingView { try await fixture.facade.saveProfile(builtIn) }
        XCTAssertEqual(saveView?.code, "models.builtInProfileImmutable", "(v)")
        let deleteProfileView = await underlyingView { try await fixture.facade.deleteProfile(id: "builtin") }
        XCTAssertEqual(deleteProfileView?.code, "models.builtInProfileImmutable", "(v) deleteProfile")

        try await fixture.facade.updateSettings(AppSettings.slice1Defaults)
        let events = await collectEvents(stream, count: 1)
        assertOnlyControlEvent(events, "(iv), (v): отказы событий не публикуют")
    }
}
