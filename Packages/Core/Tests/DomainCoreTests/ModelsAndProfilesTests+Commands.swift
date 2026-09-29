//  К35 перечня MEE-401 (план MEE-410, группа М; C-016 v10 «Команды моделей и профилей»,
//  инв. 19; задача MEE-420): каждая команда моделей и профилей пробрасывает отказ каталога
//  как `AppFacadeError.underlying` с кодом `models.*`; успешные векторы не бросают.

import XCTest
import DomainCore
import DomainTestKit

extension ModelsAndProfilesTests {

    func test_k35_modelAndProfileCommandsPropagateCatalogErrors() async throws {
        let fixture = ModelJobFixture()
        let catalog = fixture.catalog
        let facade = fixture.facade
        catalog.setCatalog([ModelJobFixture.descriptor("m1", role: .asr), ModelJobFixture.descriptor("m2", role: .asr)])
        catalog.setProfiles([ModelJobFixture.profile("builtin", asr: "m1", builtIn: true)])

        // downloadModel: успех и отказ каталога.
        try await facade.downloadModel(id: "m1", version: "1.0.0")
        let downloaded = await facade.modelState(id: "m1", version: "1.0.0")
        XCTAssertEqual(downloaded, .downloaded)
        catalog.failDownload(.downloadFailed(message: "503"), forId: "m2", version: "1.0.0")
        let downloadView = await underlyingView { try await facade.downloadModel(id: "m2", version: "1.0.0") }
        XCTAssertEqual(downloadView?.code, "models.downloadFailed")
        XCTAssertNil(downloadView?.permissionKind)

        // cancelModelDownload во время идущей загрузки — доходит до каталога (`paused`).
        catalog.setState(.downloading(fraction: 0.5), forId: "m2", version: "1.0.0")
        await facade.cancelModelDownload(id: "m2", version: "1.0.0")
        let cancelled = await facade.modelState(id: "m2", version: "1.0.0")
        guard case .paused = cancelled else { return XCTFail("ожидалось paused, получено \(cancelled)") }

        // deleteModel на модели, занятой профилем.
        catalog.failDelete(.modelInUseByProfile(modelId: "m1", profileIds: ["builtin"]), forId: "m1", version: "1.0.0")
        let deleteView = await underlyingView { try await facade.deleteModel(id: "m1", version: "1.0.0") }
        XCTAssertEqual(deleteView?.code, "models.modelInUseByProfile")
        try await facade.deleteModel(id: "m2", version: "1.0.0")

        // saveProfile/deleteProfile на встроенном профиле.
        catalog.failProfileCommand(.builtInProfileImmutable(id: "builtin"), forProfileId: "builtin")
        let edited = ModelJobFixture.profile("builtin", asr: "m2", builtIn: true)
        let saveView = await underlyingView { try await facade.saveProfile(edited) }
        XCTAssertEqual(saveView?.code, "models.builtInProfileImmutable")
        let deleteProfileView = await underlyingView { try await facade.deleteProfile(id: "builtin") }
        XCTAssertEqual(deleteProfileView?.code, "models.builtInProfileImmutable")

        // Успешные векторы профилей.
        try await facade.saveProfile(ModelJobFixture.profile("mine", asr: "m1"))
        let saved = await facade.profiles().map(\.id)
        XCTAssertTrue(saved.contains("mine"))
        try await facade.deleteProfile(id: "mine")
        let afterDelete = await facade.profiles().map(\.id)
        XCTAssertFalse(afterDelete.contains("mine"))
    }
}
