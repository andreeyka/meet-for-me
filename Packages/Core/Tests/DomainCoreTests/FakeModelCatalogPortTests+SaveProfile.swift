//  FakeModelCatalogPortTests+SaveProfile — MEE-411, инвариант 13 C-014 v6, вынесено в
//  отдельный файл: тело класса выросло за порог `file_length` SwiftLint (400 строк).

import XCTest
import DomainCore
import DomainTestKit

extension FakeModelCatalogPortTests {
    /// Бэклог приёмки #122: `resolve`/`missingModels` расходились на профиле, чей
    /// `asrModelId` вовсе не в каталоге, — потому что `saveProfile` не проверял инвариант 13
    /// и пропускал такой профиль внутрь. Закрыто здесь, не в `resolve`/`missingModels`: раз
    /// `saveProfile` — единственная дверь, через которую порт сам заводит профиль, и она
    /// проверяет `asrModelId` при входе, оба метода эту рассинхронизацию больше не увидят.
    /// `setProfiles` — тестовый обход двери (тот же класс, что `setCatalog`/`setState`),
    /// инвариантов порта не проверяет и не обязан.
    func test_mee411_saveProfileThrowsUnknownModelForUnregisteredAsrModelAndDoesNotSave() async throws {
        let port = FakeModelCatalogPort()
        port.setCatalog([descriptor(id: "asr-1")])

        do {
            try await port.saveProfile(profile(id: "p1", asrModelId: "unknown-asr"))
            XCTFail("обязан бросить unknownModel")
        } catch ModelCatalogError.unknownModel(let id, let version) {
            XCTAssertEqual(id, "unknown-asr")
            XCTAssertEqual(version, "")
        }
        let saved = await port.profiles()
        XCTAssertTrue(saved.isEmpty, "профиль с неизвестным asrModelId не сохраняется")
    }

    /// Поиск — по `id`, без версии (шапка `FakeModelCatalogPort.swift`, п. 2): профиль
    /// ссылается на модель любой зарегистрированной версии, инвариант 13 этим удовлетворён.
    func test_mee411_saveProfileSucceedsWhenAsrModelIsRegisteredByIdRegardlessOfVersion() async throws {
        let port = FakeModelCatalogPort()
        port.setCatalog([descriptor(id: "asr-1", version: "2.0.0")])

        try await port.saveProfile(profile(id: "p1", asrModelId: "asr-1"))

        let saved = await port.profiles()
        XCTAssertEqual(saved.map(\.id), ["p1"])
    }
}
