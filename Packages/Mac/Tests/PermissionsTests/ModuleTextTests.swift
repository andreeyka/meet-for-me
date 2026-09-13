//  Текстовые проверки перечня MEE-74 по исходникам `Packages/Mac/Sources/Permissions/`:
//  грепы критериев 31.а, 47, 48 и 75 (в), плюс дополнительная половина критерия 79.
//
//  Что эти пункты доказывают и чего нет, сказано планом MEE-125: они доказывают отсутствие
//  НАПИСАНИЯ, а не поведения, и ни один признак не заменяют. Признак закрывают таблица
//  неопределённых символов (`SymbolTableTests`) и символьный граф шага CI.

import Foundation
import XCTest
@testable import Permissions

final class ModuleTextTests: XCTestCase {

    private func guilty(_ needle: String, in files: [SourceFile]) -> [String] {
        files.filter { $0.text.contains(needle) }.map(\.name)
    }

    /// Строки файла без комментариев: место вызова ищется в коде, а не в пояснениях к нему.
    private func code(of file: SourceFile) -> String {
        file.text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func assertAbsent(_ needles: [String], in files: [SourceFile], _ criterion: String) {
        for needle in needles {
            XCTAssertEqual(guilty(needle, in: files), [], "\(criterion): \(needle)")
        }
    }

    // MARK: - 75 (в). Ни ключа диалога «Универсального доступа», ни вызова с параметром опций

    func test_c75c_noAccessibilityPromptSpelling() throws {
        let files = try PermissionsSources.sources()
        XCTAssertFalse(files.isEmpty)
        assertAbsent(["kAXTrusted" + "CheckOptionPrompt", "AXIsProcessTrusted" + "WithOptions"], in: files, "75 (в)")
        let callers = files.filter { code(of: $0).contains("AXIsProcessTrusted()") }.map(\.name)
        XCTAssertEqual(callers, ["SystemRightsReader.swift"],
                       "доверие читается вызовом без параметра опций, в одном месте")
    }

    // MARK: - 47, грепом. Ни Core Audio, ни приватного TCC

    func test_c47_noCoreAudioImports_noPrivateTCC() throws {
        let files = try PermissionsSources.sources()
        assertAbsent(["import CoreAudio", "import AudioToolbox", "import CoreAudioKit", "AudioHardwareCreateProcessTap",
                      "TCCAccess"], in: files, "47")
    }

    // MARK: - 48. Собственного UI нет

    func test_c48_noOwnUI() throws {
        let files = try PermissionsSources.sources()
        assertAbsent(["import SwiftUI", "NSAlert", "NSWindow", "NSView", "NSViewController"], in: files, "48")
    }

    // MARK: - 31.а, грепом. Ни настроек, ни записи в файл, ни связки ключей

    func test_c31a_noWriteSpelling() throws {
        let files = try PermissionsSources.sources()
        assertAbsent(["User" + "Defaults", "write(to:", "File" + "Handle", "Keychain", "SecItem", "NSKeyedArchiver",
                      "CFPreferences"], in: files, "31.а")
    }

    // MARK: - 75 (б), грепом. Ни разрешения имён во время исполнения

    func test_c75b_noRuntimeNameResolutionSpelling() throws {
        let files = try PermissionsSources.sources()
        assertAbsent(["dlsym", "dlopen", "NSClassFromString", "NSSelectorFromString", "@_silgen_name"],
                     in: files, "75 (б)")
    }

    // MARK: - 79, дополнительная половина: на пути request нет собственного таймера

    func test_c79_textualHalf_noTimerOnRequestPath() throws {
        let files = try PermissionsSources.sources().filter {
            ["PermissionsCore.swift", "SystemRightsReader.swift", "RightsSystem.swift"].contains($0.name)
        }
        XCTAssertEqual(files.count, 3)
        assertAbsent(["Task.sleep", "Timer", "DispatchSource", "withTimeout", "deadline"], in: files, "79")
    }

    // MARK: - Публичных типов ровно два, и только они

    func test_publicDeclarations_areTheTwoAdapters() throws {
        let files = try PermissionsSources.sources()
        let pattern = #"public\s+(?:final\s+)?(?:class|struct|enum|actor|protocol)\s+(\w+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        var names: [String] = []
        for file in files {
            let text = file.text
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) {
                    names.append(String(text[range]))
                }
            }
        }
        XCTAssertEqual(names.sorted(), ["SystemPermissions", "SystemPower"])
    }
}
