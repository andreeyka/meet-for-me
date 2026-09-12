//  Текстовые половины критериев перечня MEE-75, сторона `domain-core`: К63 (i), (iii), (iv),
//  К64 и К66. Способ Т плана MEE-126 — «текстовая проверка по исходникам, скрипт, исполняемый
//  как тест».
//
//  Область у К63 и К66 названа в самих критериях; у К64 она ПУТЕВАЯ, и здесь это решает.
//  Сплошной `grep` по `60` красит верную реализацию: `DomainDateGrammar.swift` считает этим
//  числом минуты и секунды, и к таблице весов оно отношения не имеет. Поэтому путь применения
//  определяется по тексту: файлы модуля, называющие `SignalWeights` или `signal-weights`.
//
//  Что эти пункты доказывают и чего не доказывают, сказано планом и повторено здесь: они
//  доказывают отсутствие НАПИСАНИЯ, а не отсутствие поведения. Литерал, собранный склейкой,
//  и чтение, спрятанное за вычисляемым именем, их проходят.

import XCTest
import DomainCore

final class ModuleTextTests: XCTestCase {

    /// К63 (i): чтение ресурса — одно место в модуле.
    func test_k63_resourceIsReadInExactlyOnePlace() throws {
        let sources = try moduleSources()
        let mentions = sources.filter { $0.text.contains("Bundle.module") }
        XCTAssertEqual(mentions.map(\.name), ["SignalWeights.swift"])
        let count = try XCTUnwrap(mentions.first).text.components(separatedBy: "Bundle.module")
            .count - 1
        XCTAssertEqual(count, 1, "вхождение одно, а не «один файл со многими»")
    }

    /// К63 (iii): наружу выходят значения, а не путь к файлу.
    func test_k63_publicMemberHandsOutValuesNotPaths() throws {
        let loader = try file("SignalWeights.swift")
        XCTAssertTrue(loader.contains("public static func current() throws -> SignalWeights"))
        for line in loadPathLines() where line.contains("public") {
            XCTAssertFalse(line.contains("URL"), "публичная сигнатура с URL: \(line)")
            XCTAssertFalse(line.contains("-> Data"), "публичная сигнатура, отдающая Data: \(line)")
        }
    }

    /// К63 (iv): единственная точка декодирования — вызов `DomainJSON.decode(_:from:)`.
    ///
    /// Изъятие для файла, объявляющего `DomainJSON`, взято не по снисхождению: п. 96 (а)
    /// перечня MEE-6 требует, чтобы `JSONDecoder(` встречался ТОЛЬКО внутри этого файла.
    /// Без изъятия К63 (iv), прочитанный сплошной областью, краснеет на верной реализации.
    func test_k63_decodingGoesThroughDomainJSONOnly() throws {
        let sources = try moduleSources().filter { $0.name != "DomainJSON.swift" }
        for banned in ["JSONDecoder(", "JSONSerialization", "PropertyListDecoder"] {
            let guilty = sources.filter { $0.text.contains(banned) }.map(\.name)
            XCTAssertEqual(guilty, [], "\(banned) вне файла, объявляющего DomainJSON")
        }
        XCTAssertTrue(try file("SignalWeights.swift").contains("DomainJSON.decode("))
    }

    /// К64: ноль числовых литералов, равных `signalTtlSeconds` и весу календарного сигнала,
    /// на путях их применения. Сравнение — по равенству литерала целиком.
    func test_k64_appliedNumbersAreNotWrittenAsLiterals() {
        for literal in ["60", "0.2"] {
            for line in loadPathLines() {
                XCTAssertFalse(containsWholeNumber(literal, in: line),
                               "литерал \(literal) на пути применения: \(line)")
            }
        }
    }

    /// К66: байты таблицы приходят ровно из ресурсов собранного модуля.
    func test_k66_tableBytesComeOnlyFromOwnBundle() {
        let banned = ["Bundle.main", "FileManager.default.urls(for:", "NSHomeDirectory",
                      "applicationSupportDirectory", ".libraryDirectory", "URL(fileURLWithPath:",
                      "ProcessInfo.processInfo.environment", "CommandLine"]
        let text = loadPathLines().joined(separator: "\n")
        for api in banned {
            XCTAssertFalse(text.contains(api), "\(api) на пути загрузки таблицы")
        }
    }

    // MARK: - Оснастка: чтение исходников модуля

    private func moduleSources() throws -> [ModuleSource] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DomainCore")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertFalse(names.isEmpty, "исходники модуля не найдены — проверка была бы пустой")
        return try names.map {
            ModuleSource(name: $0,
                         text: try String(contentsOf: root.appendingPathComponent($0),
                                          encoding: .utf8))
        }
    }

    private func file(_ name: String) throws -> String {
        try XCTUnwrap(try moduleSources().first { $0.name == name }?.text, "нет файла \(name)")
    }

    /// Путь применения значений таблицы: файлы модуля, называющие её типы или её файл.
    private func loadPathLines() -> [String] {
        let sources = (try? moduleSources()) ?? []
        return sources
            .filter { $0.text.contains("SignalWeights") || $0.text.contains("signal-weights") }
            .flatMap { $0.text.components(separatedBy: "\n") }
    }

    /// Литерал целиком, а не подстрока: `60` не совпадает с `60_000`, `160` и `1.60`.
    private func containsWholeNumber(_ literal: String, in line: String) -> Bool {
        let neighbours = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_."))
        var searched = Substring(line)
        while let found = searched.range(of: literal) {
            let before = found.lowerBound > searched.startIndex
                ? searched[searched.index(before: found.lowerBound)].unicodeScalars.first
                : nil
            let after = found.upperBound < searched.endIndex
                ? searched[found.upperBound].unicodeScalars.first
                : nil
            let touched = [before, after].compactMap { $0 }.contains { neighbours.contains($0) }
            if !touched {
                return true
            }
            searched = searched[found.upperBound...]
        }
        return false
    }
}

private struct ModuleSource {
    let name: String
    let text: String
}
