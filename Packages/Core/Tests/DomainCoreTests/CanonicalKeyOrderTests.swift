//  П. 154: проход `DomainJSON.canonicalizeKeyOrder(in:)` как самостоятельный механизм.
//
//  Шесть утверждений плана, и первые два обязательны вместе: порознь каждое зелено у
//  реализации, которая проход объявила и не зовёт его.
//
//  Публичность проверяется самим фактом сборки: таргет тестов берёт `DomainCore` обычным
//  импортом, без `@testable`, и непубличный член отсюда не виден (тот же приём, что у п. 80).
//
//  Прямого сравнения вывода `encode(_:)` с выводом настроенного кодировщика здесь нет ни
//  с каким знаком: «разные байты» краснеет на `Core (Linux)`, «одинаковые» — на
//  `Core + Mac (macos-14)`, и оба запрещены п. 5 перечня. Проверяемая замена обоим —
//  равенство `encode(x)` и прохода над выводом кодировщика, и она стоит ниже.

import XCTest
import DomainCore
import DomainTestKit

final class CanonicalKeyOrderTests: XCTestCase {

    // MARK: - Утверждение 2: `encode(_:)` зовёт проход после кодирования

    /// Обходом `allFixtures` всех трёх наборов, а не перечислением руками: перечисление
    /// оставляет добавленную фикстуру непокрытой. Вектор Q40.
    func test_p154_canonicalizeKeyOrder_isCalledByEncodeOnEveryFixture() throws {
        for fixture in MeetingEventFixtures.allFixtures {
            let viaPass = try DomainJSON.canonicalizeKeyOrder(in: DomainJSON.encoder().encode(fixture))
            XCTAssertEqual(try DomainJSON.encode(fixture), viaPass, "MeetingEvent")
        }
        for fixture in RecordingManifestFixtures.allFixtures {
            let viaPass = try DomainJSON.canonicalizeKeyOrder(in: DomainJSON.encoder().encode(fixture))
            XCTAssertEqual(try DomainJSON.encode(fixture), viaPass, "RecordingManifest")
        }
        for fixture in TranscriptFixtures.allFixtures {
            let viaPass = try DomainJSON.canonicalizeKeyOrder(in: DomainJSON.encoder().encode(fixture))
            XCTAssertEqual(try DomainJSON.encode(fixture), viaPass, "Transcript")
        }
    }

    // MARK: - Утверждение 3: пары переставляются целиком

    /// Ожидаемое взято из независимо собранного входа, а не из выхода прохода: иначе
    /// половина зелена по построению. Вход несёт пару `captureGroupKey` /
    /// `capturedProcesses` — единственную во всей схеме, где порядок сборок расходится
    /// (вектор Q39), — и записан так, что перестановка происходит на обеих сборках.
    func test_p154_canonicalizeKeyOrder_movesPairsWholeAndKeepsBytesInside() throws {
        let source = Self.unsortedDocument
        let result = try text(DomainJSON.canonicalizeKeyOrder(in: Data(source.utf8)))

        XCTAssertEqual(result, Self.sortedDocument, "вывод прохода записан целиком в ожидаемом")
        assertPairsPreserved(source, result)
        assertKeysSortedRecursively(result, "проход")

        //  Запись чисел (п. 112), экранирование строк (п. 111), форма `Date` (п. 107) и
        //  компактность (п. 110): те же байты, что во входе.
        for kept in ["\"scaleErrorMs\":-0", "\"threshold\":1.0e-3", "\"sampleRate\":48000",
                     "\"zulu\":\"2026-09-11T14:22:33.863Z\"", "\"joinUrl\":\"https://zoom.us/j/1\"",
                     "\"title\":\"Синхронизация\"", "\"escaped\":\"a\\\"b\""] {
            XCTAssertTrue(source.contains(kept), "вход собран не так, как утверждает тест: \(kept)")
            XCTAssertTrue(result.contains(kept), "проход изменил байты внутри пары: \(kept)")
        }
        XCTAssertFalse(result.contains(" "), "выход прохода обязан быть компактным")
    }

    // MARK: - Утверждение 4: порядок элементов массива — данные

    func test_p154_canonicalizeKeyOrder_leavesArrayOrderAlone() throws {
        let reversed = "[{\"tag\":\"zz\"},{\"tag\":\"mm\"},{\"tag\":\"aa\"}]"
        let plain = "[3,1,2]"
        XCTAssertEqual(try text(DomainJSON.canonicalizeKeyOrder(in: Data(reversed.utf8))), reversed)
        XCTAssertEqual(try text(DomainJSON.canonicalizeKeyOrder(in: Data(plain.utf8))), plain)
        let nested = "{\"b\":[{\"y\":1,\"x\":2},{\"y\":3,\"x\":4}],\"a\":0}"
        let expected = "{\"a\":0,\"b\":[{\"x\":2,\"y\":1},{\"x\":4,\"y\":3}]}"
        XCTAssertEqual(try text(DomainJSON.canonicalizeKeyOrder(in: Data(nested.utf8))), expected)
    }

    // MARK: - Утверждение 5: идемпотентность

    func test_p154_canonicalizeKeyOrder_isIdempotent() throws {
        var inputs = [Data(Self.unsortedDocument.utf8)]
        for fixture in RecordingManifestFixtures.allFixtures {
            let encoded = try DomainJSON.encode(fixture)
            inputs.append(encoded)
        }
        for fixture in TranscriptFixtures.allFixtures {
            let encoded = try DomainJSON.encode(fixture)
            inputs.append(encoded)
        }
        for fixture in MeetingEventFixtures.allFixtures {
            let encoded = try DomainJSON.encode(fixture)
            inputs.append(encoded)
        }
        for input in inputs {
            let once = try DomainJSON.canonicalizeKeyOrder(in: input)
            XCTAssertEqual(try DomainJSON.canonicalizeKeyOrder(in: once), once)
        }
    }

    // MARK: - Утверждение 6: отказ, и он ровно один

    /// Единственное место плана, где пустота `codingPath` утверждается законно: ответ даёт
    /// НАШ код на обеих сборках, а не чужой разборщик. Вход подаётся прямым вызовом —
    /// из `encode(_:)` эта ветвь недостижима, и вектора «`encode(_:)` бросил
    /// `dataCorrupted`» не существует.
    func test_p154_canonicalizeKeyOrder_rejectsBytesThatAreNotJSON() {
        for source in ["", "не документ", "{", "{\"a\"}", "{\"a\":}", "{\"a\":1}{",
                       "[1,]", "01", "\"без закрывающей", "{\"a\":1,}"] {
            XCTAssertThrowsError(try DomainJSON.canonicalizeKeyOrder(in: Data(source.utf8)),
                                 "ожидался отказ на «\(source)»") { error in
                guard let decoding = error as? DecodingError,
                      case .dataCorrupted(let context) = decoding else {
                    XCTFail("ожидался dataCorrupted, получено \(error)")
                    return
                }
                XCTAssertEqual(context.codingPath.count, 0, "codingPath обязан быть пуст")
            }
        }
    }

    /// Документ верхнего уровня — любое значение RFC 8259, и байты его проход не трогает.
    func test_p154_canonicalizeKeyOrder_acceptsEveryShapeOfDocument() throws {
        for source in ["{}", "[]", "true", "false", "null", "-0", "1.0e-3", "\"строка\"",
                       "[[],{},[{}]]"] {
            XCTAssertEqual(try text(DomainJSON.canonicalizeKeyOrder(in: Data(source.utf8))),
                           source, source)
        }
    }

    // MARK: - Оснастка

    private func text(_ data: Data) throws -> String {
        try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }

    /// Мультимножество пар «ключ: значение» каждого объекта до прохода и после совпадает.
    /// Сравниваются мультимножества, а не последовательности: перестановка пар внутри
    /// объекта меняет и порядок объектов при обходе сверху вниз.
    private func assertPairsPreserved(_ before: String, _ after: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let source = Self.normalise(PairScanner.pairLists(in: before))
        let result = Self.normalise(PairScanner.pairLists(in: after))
        XCTAssertFalse(source.isEmpty, "объектов не найдено — сравнивать нечего",
                       file: file, line: line)
        XCTAssertEqual(source, result, "мультимножество пар изменилось", file: file, line: line)
    }

    private static func normalise(_ lists: [[String]]) -> [[String]] {
        lists.map { $0.sorted() }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// Вход собран здесь, а не взят у кодировщика: ключи стоят не в порядке по UTF-8 на
    /// всякой сборке, и перестановка на нём происходит всегда.
    private static let unsortedDocument =
        "{\"capturedProcesses\":[{\"pid\":2,\"bundleId\":\"us.zoom.xos\"}," +
        "{\"pid\":1,\"bundleId\":\"a\"}]," +
        "\"captureGroupKey\":\"bundle:us.zoom.xos\"," +
        "\"zulu\":\"2026-09-11T14:22:33.863Z\"," +
        "\"joinUrl\":\"https://zoom.us/j/1\"," +
        "\"title\":\"Синхронизация\"," +
        "\"escaped\":\"a\\\"b\"," +
        "\"numbers\":{\"scaleErrorMs\":-0,\"threshold\":1.0e-3,\"sampleRate\":48000," +
        "\"flag\":true,\"nothing\":null}}"

    /// Тот же документ с ключами по UTF-8 на каждом уровне: `captureGroupKey` раньше
    /// `capturedProcesses` — в общем префиксе `capture` дальше идут `G` (0x47) и `d` (0x64).
    private static let sortedDocument =
        "{\"captureGroupKey\":\"bundle:us.zoom.xos\"," +
        "\"capturedProcesses\":[{\"bundleId\":\"us.zoom.xos\",\"pid\":2}," +
        "{\"bundleId\":\"a\",\"pid\":1}]," +
        "\"escaped\":\"a\\\"b\"," +
        "\"joinUrl\":\"https://zoom.us/j/1\"," +
        "\"numbers\":{\"flag\":true,\"nothing\":null,\"sampleRate\":48000," +
        "\"scaleErrorMs\":-0,\"threshold\":1.0e-3}," +
        "\"title\":\"Синхронизация\"," +
        "\"zulu\":\"2026-09-11T14:22:33.863Z\"}"
}

/// Пары «ключ: значение» каждого объекта текста, по объектам. Значение скалярного поля
/// берётся байтами как записано — на нём и видно, изменил ли проход хоть один байт внутри
/// ключа или внутри значения; составное значение обозначается меткой `{}` или `[]`, потому
/// что его собственные пары сравниваются на СВОЁМ уровне, а уровней у сравнения столько
/// же, сколько объектов в документе.
///
/// Разбор структурный: строковые литералы пропускаются целиком, и запись, похожая на пару,
/// внутри строки парой не становится.
private struct PairScanner {

    private let bytes: [UInt8]
    private var index = 0
    private var lists: [[String]] = []
    /// Номер объекта в `lists` для каждой открытой фигурной скобки; `nil` — для квадратной.
    private var stack: [Int?] = []
    private var pendingKey: String?
    private var expectKey = false

    static func pairLists(in text: String) -> [[String]] {
        var scanner = PairScanner(bytes: Array(text.utf8))
        scanner.run()
        return scanner.lists
    }

    private mutating func run() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                readString()
            case 0x7B:
                openFrame(marker: "{}", list: true)
            case 0x5B:
                openFrame(marker: "[]", list: false)
            case 0x7D, 0x5D:
                closeFrame()
            case 0x3A:
                index += 1
            case 0x2C:
                index += 1
                expectKey = (stack.last ?? nil) != nil
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                let value = readLiteral()
                appendPair(value)
            }
        }
    }

    private mutating func readString() {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C {
                index += 2
                continue
            }
            index += 1
            if byte == 0x22 {
                break
            }
        }
        let scanned = text(start..<index)
        if expectKey, currentList != nil {
            pendingKey = scanned
            expectKey = false
            return
        }
        appendPair(scanned)
    }

    private mutating func readLiteral() -> String {
        let start = index
        while index < bytes.count {
            switch bytes[index] {
            case 0x2C, 0x7D, 0x5D, 0x3A, 0x20, 0x09, 0x0A, 0x0D:
                return text(start..<index)
            default:
                index += 1
            }
        }
        return text(start..<index)
    }

    private mutating func openFrame(marker: String, list: Bool) {
        appendPair(marker)
        if list {
            lists.append([])
            stack.append(lists.count - 1)
        } else {
            stack.append(nil)
        }
        index += 1
        expectKey = list
    }

    private mutating func closeFrame() {
        if !stack.isEmpty {
            stack.removeLast()
        }
        index += 1
        expectKey = false
        pendingKey = nil
    }

    /// Пара записывается только там, где у значения есть ключ: элемент массива парой не является.
    private mutating func appendPair(_ value: String) {
        guard let key = pendingKey, let list = currentList else { return }
        pendingKey = nil
        lists[list].append("\(key):\(value)")
    }

    private var currentList: Int? {
        stack.last ?? nil
    }

    private func text(_ range: Range<Int>) -> String {
        String(bytes: bytes[range], encoding: .utf8) ?? "<не UTF-8>"
    }
}
