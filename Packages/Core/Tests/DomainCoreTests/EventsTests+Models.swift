//  К33, вектор 4 перечня MEE-401 (C-016 v10 инв. 15; задача MEE-420): `downloadModel` и
//  `deleteModel` публикуют `modelsChanged` до возврата управления. Прежде вектор был вне зоны
//  (группа М не реализована — шапка `EventsTests.swift`).

import XCTest
import DomainCore
import DomainTestKit

extension EventsTests {

    func test_k33_downloadAndDeleteModel_publishModelsChanged() async throws {
        let fixture = ModelJobFixture()
        fixture.catalog.setCatalog([ModelJobFixture.descriptor("m1", role: .asr)])
        let stream = fixture.facade.events()
        try await fixture.facade.downloadModel(id: "m1", version: "1.0.0")
        try await fixture.facade.deleteModel(id: "m1", version: "1.0.0")
        let events = await collectEvents(stream, count: 2)
        XCTAssertEqual(events, [.modelsChanged, .modelsChanged])
    }
}
