//  Критерии перечня MEE-74 по таблице неопределённых символов таргета `Permissions`: 31.а, 47,
//  75 (а) и 75 (б). Вход — `nm -u` по объектным файлам продукта `swift build`.
//
//  Пункт (б) критерия 75 читается по признаку («символ, чья работа — вернуть адрес функции или
//  класс по строке, вычисленной во время исполнения»), и чтения таблицы целиком тест не заменяет:
//  он помечает известные примеры признака и печатает всю таблицу в журнал, чтобы приёмка прочла её.

import Foundation
import XCTest
@testable import Permissions

final class SymbolTableTests: XCTestCase {

    private static var cachedSymbols: [String]?

    /// Имена неопределённых символов таргета, без повторов, по алфавиту.
    private func undefinedSymbols() throws -> [String] {
        if let cached = Self.cachedSymbols { return cached }
        let objects = try PermissionsSources.objectFiles()
        XCTAssertFalse(objects.isEmpty, "объектные файлы таргета Permissions")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-u"] + objects.map(\.path)
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let names = (String(bytes: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map { String($0.split(separator: " ").last ?? "") }
            .filter { $0.hasPrefix("_") }
        let symbols = Array(Set(names)).sorted()
        Self.cachedSymbols = symbols
        print("Таблица неопределённых символов таргета Permissions — \(symbols.count) имён:")
        for symbol in symbols {
            print("  \(symbol)")
        }
        return symbols
    }

    private func assertNone(_ symbols: [String], containing fragments: [String], _ criterion: String) {
        for fragment in fragments {
            let found = symbols.filter { $0.contains(fragment) }
            XCTAssertEqual(found, [], "\(criterion): \(fragment)")
        }
    }

    // MARK: - 75 (а). Вызова с параметром опций нет

    func test_c75a_noAXIsProcessTrustedWithOptions() throws {
        let symbols = try undefinedSymbols()
        assertNone(symbols, containing: ["AXIsProcessTrusted" + "WithOptions"], "75 (а)")
        XCTAssertTrue(symbols.contains("_AXIsProcessTrusted"), "доверие читается вызовом без параметра опций")
    }

    // MARK: - 75 (б). Разрешения имён во время исполнения нет — известные примеры признака

    func test_c75b_noRuntimeNameResolution_knownExamples() throws {
        let symbols = try undefinedSymbols()
        assertNone(symbols, containing: ["_dlsym", "_dlopen", "_NSClassFromString", "_NSSelectorFromString",
                                         "_objc_lookUpClass", "_objc_getClass", "_CFBundleGetFunctionPointerForName",
                                         "_sel_registerName", "_class_getMethodImplementation"], "75 (б)")
    }

    // MARK: - 47. Ни символа, поднимающего промпт на системный звук

    func test_c47_noProcessTapSymbols() throws {
        let symbols = try undefinedSymbols()
        assertNone(symbols, containing: ["AudioHardwareCreateProcessTap", "AudioHardwareDestroyProcessTap",
                                         "AudioObjectGetPropertyData", "_TCCAccess"], "47")
    }

    // MARK: - 31.а. Ни семейства записи на диск

    func test_c31a_noWriteFamilies() throws {
        let symbols = try undefinedSymbols()
        assertNone(symbols, containing: ["User" + "Defaults", "CFPreferences", "createFile", "createDirectory",
                                         "DataV5write", "File" + "Handle", "NSKeyedArchiver", "SecItemAdd",
                                         "SecItemUpdate", "sqlite3_"], "31.а")
    }
}
