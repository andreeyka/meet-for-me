//  FileLayoutTests — К21 перечня MEE-189 (группа C), владелец: DEV-2.
//
//  `FileLayout` объявлен в `DomainCore` (C-010 v7 §0 — дельта Й перечня МЕЕ-189,
//  раздел 1), это чужой тип из разрешённого списка инварианта 19. Тест здесь по
//  умолчанию контракта («Проверяются в StorageTests, если не сказано иное»).
//
//  РАСХОЖДЕНИЕ С МЕСТОМ ИЗ ПЛАНА МЕЕ-311 (называю, не правлю — не моя зона,
//  `docs/process.md` §1): К21 размечен местом «Л» (`Core (Linux)` безусловно), но
//  физически живёт в `StorageTests`, а этот таргет в манифесте объявлен только
//  НЕ на Linux (`#if !os(Linux)`, MEE-321, условие Г ложно) — на `Core (Linux)`
//  таргета `StorageTests` в графе SwiftPM нет вовсе, и этот тест там не
//  собирается и не исполняется ни разу. Фактически К21 исполняется только в
//  работе `Core + Mac (macos-14)`, как и все пункты «Л|М(Г)» — вопреки своей
//  безусловной пометке. То же расхождение — у К5 (тоже физически в
//  `StorageTests`).

import XCTest
import DomainCore

final class FileLayoutTests: XCTestCase {

    func testK21_pathsMatchLayoutTable() {
        let root = URL(fileURLWithPath: "/tmp/fixture-root", isDirectory: true)
        let layout = FileLayout(root: root)

        XCTAssertEqual(layout.databaseURL().path, "/tmp/fixture-root/db.sqlite")
        XCTAssertEqual(layout.recordingsRoot().path, "/tmp/fixture-root/recordings")
        XCTAssertEqual(layout.recordingDirectory("A1B2").path, "/tmp/fixture-root/recordings/A1B2")
        XCTAssertEqual(layout.manifestURL("A1B2").path, "/tmp/fixture-root/recordings/A1B2/manifest.json")
        XCTAssertEqual(
            layout.transcriptURL("A1B2", index: 2).path,
            "/tmp/fixture-root/recordings/A1B2/transcript.v2.json"
        )
        XCTAssertEqual(
            layout.modelDirectory(engine: "e", modelId: "m", version: "1.0").path,
            "/tmp/fixture-root/models/e/m@1.0"
        )
        XCTAssertEqual(layout.logsDirectory().path, "/tmp/fixture-root/logs")
    }
}
