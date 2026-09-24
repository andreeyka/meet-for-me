//  Текстовые критерии перечня MEE-310 по исходникам `Packages/Mac/Sources/Capture/`: К8, К19.
//  Способ Г/механически (план MEE-315 §1): CI-агностично, применимо без сборки и без Mac —
//  образец Detector, `DetectorTests/ModuleTextTests.swift`.

import Foundation
import XCTest
@testable import Capture

final class ModuleTextTests: XCTestCase {

    private func sources() throws -> [SourceFile] { try CaptureSources.sources() }

    private func guilty(_ needle: String, in files: [SourceFile]) -> [String] {
        files.filter { $0.text.contains(needle) }.map(\.name)
    }

    // MARK: - К8. Voice processing не включается никогда (инвариант 8)

    func test_k08_voiceProcessingNeverEnabled() throws {
        let files = try sources()
        XCTAssertEqual(guilty("setVoiceProcessingEnabled", in: files), [])
        XCTAssertEqual(guilty("kAudioUnitSubType_VoiceProcessingIO", in: files), [])
    }

    // MARK: - К19. Порт не знает о PermissionsPort (инвариант 17)

    // СТРОКА: план MEE-315 называет для К19 способ В (символьный граф), сделано способом Г
    // (греп). `.github/scripts/symbol-graph-surface.py` (владелец — CI, вне зоны этой задачи)
    // разбирает только ПУБЛИЧНУЮ поверхность таргета против инварианта 25-подобных списков —
    // инвариант 17 запрещает ссылку на `PermissionsPort` НА ЛЮБОМ пути, не только в публичной
    // сигнатуре, и этот барьер её не ловит. Свой инструмент способа В означал бы отдельный вызов
    // `swift symbolgraph-extract` и разбор JSON изнутри теста — вне зоны трёх директорий задачи
    // и цены одного критерия. Решение о способе В отдельным инструментом — за РП/QA.
    func test_k19_portDoesNotKnowPermissionsPort() throws {
        let files = try sources()
        for needle in ["PermissionsPort", "PermissionRequestOutcome", "import Permissions"] {
            XCTAssertEqual(guilty(needle, in: files), [], needle)
        }
    }
}
