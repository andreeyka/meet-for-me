//  DomainJSONInt32ArrayTests — C-001 v14 §0.4, `decodeBounded`/`decodeBoundedIfPresent`
//  на `[Int32]` (IR-090, MEE-225), владелец: DEV-2.
//
//  Векторы — по §0.4 для массива: по элементам те же четыре проверки, что у скалярного
//  `Int32` (конечность, целость, диапазон §0.2 п. 9, диапазон типа); отказ — без индекса
//  элемента в пути (тот же приём, что `decodeFinite([Float].self, …)`).

import XCTest
import DomainCore

/// Вынесено на верхний уровень тем же приёмом, что `TranscriptNested.swift`/`EngineResults.swift`
/// для чужих `CodingKeys`: объявленный ВНУТРИ `Probe`/`OptionalProbe` (сами уже вложены в
/// класс теста) он был бы вторым уровнем вложенности — предел SwiftLint `nesting` держит один.
private enum ProbeCodingKeys: String, CodingKey { case values }

final class DomainJSONInt32ArrayTests: XCTestCase {

    private struct Probe: Decodable {
        let values: [Int32]

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: ProbeCodingKeys.self)
            values = try box.decodeBounded([Int32].self, forKey: .values)
        }
    }

    private struct OptionalProbe: Decodable {
        let values: [Int32]?

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: ProbeCodingKeys.self)
            values = try box.decodeBoundedIfPresent([Int32].self, forKey: .values)
        }
    }

    private func decode(_ json: String) throws -> Probe {
        try DomainJSON.decode(Probe.self, from: Data(json.utf8))
    }

    // MARK: - Валидный массив

    func testValidArrayDecodesElementwise() throws {
        let probe = try decode(#"{"values":[-2147483648,0,2147483647]}"#)
        XCTAssertEqual(probe.values, [Int32.min, 0, Int32.max])
    }

    // MARK: - Непредставимый элемент (1e400 — за пределами Double)

    func testUnrepresentableElementThrowsDataCorrupted() throws {
        XCTAssertThrowsError(try decode(#"{"values":[0,1e400]}"#)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("ожидался DecodingError.dataCorrupted, получено \(error)")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["values"], "путь — ключ поля, без индекса")
        }
    }

    // MARK: - Форма литерала свободна (п. 128): «4.8e4» выглядит дробным, значение — целое 48000

    /// Тот же вектор `4.8e4`, что `test_p128_literalFormIsFreeValueIsBounded`
    /// (`IntegerReadingTests.swift`) для скалярного `Int32` (`RecordingManifest.Track.sampleRate`) —
    /// здесь на элементе массива: научная запись с нулевой дробной частью проходит целость
    /// (`raw == raw.rounded(.towardZero)`), значение принято, не отвергнуто.
    func testScientificNotationLiteralWithZeroFractionIsAcceptedAsElement() throws {
        let probe = try decode(#"{"values":[4.8e4]}"#)
        XCTAssertEqual(probe.values, [48_000])
    }

    /// Настоящая дробная часть (не только форма литерала) — отвергается на элементе так же,
    /// как на скалярном `Int32` (`test_p128_nonIntegralLiteralIsBrokenJSON`).
    func testGenuinelyFractionalElementThrowsDataCorrupted() throws {
        XCTAssertThrowsError(try decode(#"{"values":[0,4.8]}"#)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("ожидался DecodingError.dataCorrupted, получено \(error)")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["values"], "путь — ключ поля, без индекса")
            XCTAssertTrue(context.debugDescription.contains("целое"), context.debugDescription)
        }
    }

    // MARK: - Элемент вне диапазона Int32 (в безопасном диапазоне §0.2 п. 9, но вне типа)

    func testElementBeyondInt32RangeThrowsDataCorrupted() throws {
        let beyondInt32 = Int64(Int32.max) + 1
        XCTAssertThrowsError(try decode(#"{"values":[0,\#(beyondInt32)]}"#)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("ожидался DecodingError.dataCorrupted, получено \(error)")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["values"])
            XCTAssertTrue(context.debugDescription.contains("Int32") || context.debugDescription.contains("тип"),
                         context.debugDescription)
        }
    }

    // MARK: - decodeBoundedIfPresent на отсутствующем ключе

    func testIfPresentReturnsNilForMissingKey() throws {
        let probe = try DomainJSON.decode(OptionalProbe.self, from: Data(#"{}"#.utf8))
        XCTAssertNil(probe.values)
    }

    func testIfPresentReturnsNilForNullKey() throws {
        let probe = try DomainJSON.decode(OptionalProbe.self, from: Data(#"{"values":null}"#.utf8))
        XCTAssertNil(probe.values)
    }

    func testIfPresentDecodesElementwiseWhenPresent() throws {
        let probe = try DomainJSON.decode(OptionalProbe.self, from: Data(#"{"values":[1,2,3]}"#.utf8))
        XCTAssertEqual(probe.values, [1, 2, 3])
    }
}
