//  AppFacadeGeneralTests — К1 перечня MEE-401, план MEE-410 группа А, MEE-420.
//
//  Механический класс (1): читает исходный текст `AppFacade.swift`/`AppFacadeReadModels
//  .swift` через `#filePath` — не переписывает утверждение самим собой, а проверяет
//  дерево. Инвариант 1 C-016: «ни один тип, объявленный в этом контракте, не является
//  типом GRDB, CoreAudio, EventKit, AppKit или SwiftUI: фасад и его модели чтения
//  собираются на Linux» — сам факт зелёной сборки `Core (Linux)` это уже доказывает
//  (ни один из этих фреймворков не существует на Linux), тест — вторая, независимая
//  проверка тем же приёмом, что и остальные «мех.»-критерии этого перечня.

import XCTest

final class AppFacadeGeneralTests: XCTestCase {

    private static let forbiddenFrameworks = ["GRDB", "CoreAudio", "EventKit", "AppKit", "SwiftUI"]

    func test_k01_publicSurfaceHasNoMacFrameworkTypes() throws {
        for fileName in ["AppFacade.swift", "AppFacadeReadModels.swift"] {
            let source = try Self.readSource(named: fileName)
            let importLines = source
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") }
            XCTAssertEqual(importLines, ["import Foundation"], "\(fileName): единственный import")
            for framework in Self.forbiddenFrameworks {
                XCTAssertFalse(
                    source.contains(framework), "\(fileName) ссылается на \(framework) — недопустимо (инв. 1)"
                )
            }
        }
    }

    private static func readSource(named fileName: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url = url
            .appendingPathComponent("Sources")
            .appendingPathComponent("DomainCore")
            .appendingPathComponent(fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
