//  Текстовые критерии перечня MEE-75 по исходникам `Packages/Mac/Sources/Detector/`:
//  К4, К9, К10, К25, К26, К55, К69 и механический след второй половины инварианта 23.
//
//  Способ Т плана MEE-126. Что эти пункты доказывают и чего нет, сказано планом: они доказывают
//  отсутствие НАПИСАНИЯ, а не поведения. Литерал, собранный склейкой, и вызов за вычисляемым
//  именем их проходят. Клаузы с путевой областью (К4 — срок подтверждения, К26 (3)) исполнены
//  здесь по файлам, где этот путь живёт; вердикт по ним ставится ещё и чтением.

import DomainCore
import Foundation
import XCTest
@testable import Detector

final class ModuleTextTests: XCTestCase {

    private func sources() throws -> [SourceFile] { try DetectorSources.sources() }

    private func guilty(_ needle: String, in files: [SourceFile]) -> [String] {
        files.filter { $0.text.contains(needle) }.map(\.name)
    }

    private func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - К4. Ни ключей, ни строк таблиц, ни весов, ни срока подтверждения литералами

    func test_k04_noTableValuesWrittenAsLiterals() throws {
        let shipped = try RuleTables.shipped.get()
        let weights = try SignalWeights.current()
        let forbiddenStrings = Set(["zoom", "meet", "teams", "webex", "telemost", "kontur", "salutejazz", "jitsi"]
            + shipped.browsers + shipped.clients.flatMap(\.bundleIds))
        let forbiddenWeights = [PublishedKind.clientRunning, .clientAudioOutput, .microphoneInUse]
            .map { weights.weight(for: $0.signalKind) }
        for file in try sources() {
            for literal in try matches(#""(?:[^"\\\n]|\\.)*""#, in: file.text) {
                let value = String(literal.dropFirst().dropLast())
                XCTAssertFalse(forbiddenStrings.contains(value), "\(file.name): литерал \(literal)")
            }
            for number in try numbers(in: file.text) {
                XCTAssertFalse(forbiddenWeights.contains(number), "\(file.name): вес \(number) литералом")
            }
        }
        let ttl = weights.signalTtlSeconds
        let deadlineShares = Set([ttl, ttl - 1] + (2...ttl).filter { ttl % $0 == 0 }.map { ttl / $0 })
        for file in try sources() where ["ConfirmationPolicy.swift", "SignalEngine.swift"].contains(file.name) {
            for number in try numbers(in: file.text) {
                XCTAssertFalse(deadlineShares.contains(where: { Double($0) == number }),
                               "\(file.name): срок или его доля \(number) литералом на пути срока подтверждения")
            }
        }
    }

    private func numbers(in text: String) throws -> [Double] {
        try matches(#"(?<![\w.])\d+(?:\.\d+)?(?![\w.])"#, in: text).compactMap(Double.init)
    }

    // MARK: - К9. Единственная точка декодирования — DomainJSON

    func test_k09_decodingOnlyThroughDomainJSON() throws {
        let files = try sources()
        for banned in ["JSONDecoder(", "JSONSerialization", "PropertyListDecoder"] {
            XCTAssertEqual(guilty(banned, in: files), [], banned)
        }
        XCTAssertEqual(guilty("DomainJSON.decode(", in: files), ["RuleTables.swift"])
    }

    // MARK: - К10 и инвариант 23. Байты — только из ресурсов собранного модуля

    func test_k10_bytesOnlyFromModuleResources_noWeightsFileName() throws {
        let files = try sources()
        let banned = ["Bundle.main", "FileManager.default.urls(for:", "NSHomeDirectory", "applicationSupportDirectory",
                      ".libraryDirectory", "URL(fileURLWithPath:", "ProcessInfo.processInfo.environment", "CommandLine"]
        for needle in banned {
            XCTAssertEqual(guilty(needle, in: files), [], needle)
        }
        XCTAssertEqual(guilty("signal-weights.json", in: files), [])
        XCTAssertEqual(guilty("Bundle.module", in: files), ["DetectorResources.swift"], "чтение ресурса — одно место")
        let reader = try XCTUnwrap(files.first { $0.name == "DetectorResources.swift" })
        XCTAssertEqual(reader.text.components(separatedBy: "Bundle.module").count - 1, 1)
    }

    // MARK: - К25. В сеть не ходит, подпроцессов не запускает

    func test_k25_noNetworkAndNoSubprocess() throws {
        let files = try sources()
        for needle in ["URLSession", "NWConnection", "NWBrowser", "CFStream", "import Network"] {
            XCTAssertEqual(guilty(needle, in: files), [], needle)
        }
        for file in files {
            XCTAssertEqual(try matches(#"(?<![A-Za-z0-9_])Process\s*[(.]"#, in: file.text), [], file.name)
        }
    }

    // MARK: - К26. Правило §4.1 — только из domain-core

    func test_k26_noOwnCopyOfTheMatchingRule() throws {
        let files = try sources()
        for needle in ["hasPrefix(", ".starts(with:", "responsibleBundleId ??"] {
            XCTAssertEqual(guilty(needle, in: files), [], "клауза (1): \(needle)")
        }
        let keyWords = ["appKey", "bundleId", "responsibleBundleId", "browsers", "bundleIds"]
        for file in files {
            for line in file.text.components(separatedBy: .newlines)
            where line.contains("hasSuffix(") || line.contains("range(of:") {
                XCTAssertFalse(keyWords.contains { line.contains($0) }, "клауза (4), \(file.name): \(line)")
            }
        }
        XCTAssertFalse(guilty("bundleKeyMatches(appKey:", in: files).isEmpty, "клауза (2): сравнение — чужой функцией")
    }

    // MARK: - К55. Порт не предсказывает право

    func test_k55_portDoesNotPredictPermission() throws {
        let files = try sources()
        let banned = ["PermissionsPort", "status(of:", "AVCaptureDevice", "TCCAccessPreflight", "requestAccess",
                      "operatingSystemVersion", "#available("]
        for needle in banned {
            XCTAssertEqual(guilty(needle, in: files), [], needle)
        }
        XCTAssertEqual(guilty(".permissionRequired(", in: files), ["HALStatusMapping.swift"])
    }

    // MARK: - К69. Фейк — не эталон: следа в модуле и в его тестах нет

    func test_k69_fakeLeavesNoTraceInModuleOrItsTests() throws {
        // Имя собрано склейкой: этот файл сам лежит в области критерия, и написанное одной
        // строкой оно было бы тем вхождением, которое критерий запрещает.
        let fake = "Fake" + "ProcessMonitorPort"
        XCTAssertEqual(guilty(fake, in: try sources()), [])
        XCTAssertEqual(guilty(fake, in: try DetectorSources.tests()), [])
        XCTAssertEqual(guilty("DomainTestKit", in: try sources()), [])
    }
}
