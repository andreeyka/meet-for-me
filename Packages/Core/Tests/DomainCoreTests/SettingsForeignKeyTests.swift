//  SettingsForeignKeyTests — C-016 v11 §2.1 (IR-141, редакционная правка `7908dbf9` в MEE-435):
//  ключ `modelCatalog.userProfiles` принадлежит C-014, вне отображения `AppSettings`.
//  `settings()` его не читает — строка с любыми байтами не меняет ответ и не даёт
//  `settingsUnreadable`; `updateSettings` пишет только ключи-имена полей `AppSettings`, этот — никогда.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class SettingsForeignKeyTests: XCTestCase {

    private let foreignKey = "modelCatalog.userProfiles"

    func test_settingsIgnoresModelCatalogUserProfilesRowWithAnyBytes() async throws {
        for bytes in [Data("не JSON вовсе".utf8), Data("[{\"id\":\"p\"}]".utf8), Data()] {
            let fixture = FacadeV11Fixture()
            fixture.repositories.settings.seed([foreignKey: bytes])

            let settings = try await fixture.facade.settings()

            XCTAssertEqual(settings, AppSettings.slice1Defaults, "байты \(bytes.count) Б не влияют на ответ")
        }
    }

    func test_updateSettingsNeverWritesModelCatalogUserProfilesKey() async throws {
        let fixture = FacadeV11Fixture()
        let foreignBytes = Data("{\"owner\":\"C-014\"}".utf8)
        fixture.repositories.settings.seed([foreignKey: foreignBytes])

        try await fixture.facade.updateSettings(AppSettings.slice1Defaults)

        let writtenKeys = fixture.repositories.settings.callLog.calls(port: InMemorySettingsRepository.portName)
            .filter { $0.method == "setValue(_:forKey:)" }
            .flatMap(\.arguments)
        XCTAssertFalse(writtenKeys.isEmpty, "иначе проверка вакуумна")
        XCTAssertFalse(writtenKeys.contains(foreignKey))
        let stored = try await fixture.repositories.settings.value(forKey: foreignKey)
        XCTAssertEqual(stored, foreignBytes, "строка чужого ключа не тронута")
    }
}
