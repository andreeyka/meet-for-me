//  ModelsAndProfilesTests — план MEE-410, группа М, файл по плану. MEE-448 (сверка покрытия
//  MEE-401, `484179e8`): К36 — `modelState(id:version:)` уже реализован сквозным
//  (`AppFacadeImpl.swift`), теста не было. К35 (команды моделей и профилей) ждёт группу М
//  (MEE-420) и этим файлом не заявляется.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class ModelsAndProfilesTests: XCTestCase {

    private func makeFacade(modelCatalog: FakeModelCatalogPort) -> AppFacadeImpl {
        let repositories = InMemoryRepositories()
        return AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: modelCatalog,
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            clock: { Date() }
        )
    }

    // MARK: - К36 (§1, modelState): ModelState.paused(bytesOnDisk:) проходит без изменения поля

    /// Две модели на паузе с разными `bytesOnDisk`, ни один не выводим из `sizeBytes`
    /// дескриптора: фасад, пересчитывающий поле сам (или перепутавший `id`/`version` при
    /// передаче в порт), даст другое значение хотя бы у одной.
    func test_k36_modelStatePausedBytesOnDiskPassThroughUnchanged() async {
        let catalog = FakeModelCatalogPort()
        catalog.setCatalog([
            descriptor(id: "asr-a", version: "1.0.0", sizeBytes: 1_000_000),
            descriptor(id: "asr-a", version: "2.0.0", sizeBytes: 2_000_000),
            descriptor(id: "asr-b", version: "1.0.0", sizeBytes: 3_000_000)
        ])
        catalog.setState(.paused(bytesOnDisk: 123_457), forId: "asr-a", version: "1.0.0")
        catalog.setState(.paused(bytesOnDisk: 987_653), forId: "asr-a", version: "2.0.0")
        catalog.setState(.downloaded, forId: "asr-b", version: "1.0.0")
        let facade = makeFacade(modelCatalog: catalog)

        let first = await facade.modelState(id: "asr-a", version: "1.0.0")
        let second = await facade.modelState(id: "asr-a", version: "2.0.0")
        let other = await facade.modelState(id: "asr-b", version: "1.0.0")

        XCTAssertEqual(first, .paused(bytesOnDisk: 123_457))
        XCTAssertEqual(second, .paused(bytesOnDisk: 987_653))
        XCTAssertEqual(other, .downloaded)
        let portFirst = await catalog.state(id: "asr-a", version: "1.0.0")
        XCTAssertEqual(first, portFirst, "значение фасада равно значению порта")
    }
}
