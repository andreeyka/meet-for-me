//  Оснастка тестов: утверждения об ошибках и сборка входного JSON текстом.
//
//  Вход подаётся текстом JSON везде, где он в JSON выразим; значения, которых в тексте
//  записать нечем (`Double.nan`, `1 << 53` из кода), подаются публичным инициализатором.
//
//  Утверждение на отказ сравнивает только четыре структурных поля ошибки: текст `message`
//  в контракт не входит, и утверждение на него было бы дефектом теста.

import XCTest
import DomainCore

// MARK: - Утверждения

func assertInvariant<Value>(
    _ expression: @autoclosure () throws -> Value,
    contract: String,
    type: String,
    invariant: Int,
    path: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), "ожидался DomainValidationError", file: file, line: line) { error in
        guard let failure = error as? DomainValidationError else {
            XCTFail("ожидался DomainValidationError, получено \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(failure.contract, contract, "contract", file: file, line: line)
        XCTAssertEqual(failure.type, type, "type", file: file, line: line)
        XCTAssertEqual(failure.invariant, invariant, "invariant", file: file, line: line)
        XCTAssertEqual(failure.path, path, "path", file: file, line: line)
    }
}

/// Отказ разбора: тип ошибки и ключ, названный в `codingPath`.
func assertCorrupted<Value>(
    _ expression: @autoclosure () throws -> Value,
    key: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), "ожидался DecodingError", file: file, line: line) { error in
        guard let decoding = error as? DecodingError,
              case .dataCorrupted(let context) = decoding else {
            XCTFail("ожидался dataCorrupted, получено \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(context.codingPath.last?.stringValue, key, "ключ", file: file, line: line)
    }
}

func assertKeyNotFound<Value>(
    _ expression: @autoclosure () throws -> Value,
    key: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), "ожидался keyNotFound", file: file, line: line) { error in
        guard let decoding = error as? DecodingError,
              case .keyNotFound(let missing, _) = decoding else {
            XCTFail("ожидался keyNotFound, получено \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(missing.stringValue, key, "ключ", file: file, line: line)
    }
}

func assertTypeMismatch<Value>(
    _ expression: @autoclosure () throws -> Value,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), "ожидался typeMismatch", file: file, line: line) { error in
        guard let decoding = error as? DecodingError,
              case .typeMismatch = decoding else {
            XCTFail("ожидался typeMismatch, получено \(error)", file: file, line: line)
            return
        }
    }
}

/// Полный путь ключей ошибки разбора — для утверждений о порядке отказа.
func corruptedPath<Value>(_ expression: @autoclosure () throws -> Value) -> [String] {
    do {
        _ = try expression()
        return []
    } catch let error as DecodingError {
        guard case .dataCorrupted(let context) = error else { return [] }
        return context.codingPath.map(\.stringValue)
    } catch {
        return []
    }
}

// MARK: - Разбор и запись

func decodeEvent(_ text: String) throws -> MeetingEvent {
    try DomainJSON.decode(MeetingEvent.self, from: Data(text.utf8))
}

func decodeManifest(_ text: String) throws -> RecordingManifest {
    try DomainJSON.decode(RecordingManifest.self, from: Data(text.utf8))
}

func decodeTranscript(_ text: String) throws -> Transcript {
    try DomainJSON.decode(Transcript.self, from: Data(text.utf8))
}

func encodedText<Value: Encodable>(_ value: Value) throws -> String {
    try XCTUnwrap(String(bytes: try DomainJSON.encode(value), encoding: .utf8))
}

func makeUUID(_ text: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: text))
}

func makeURL(_ text: String) throws -> URL {
    try XCTUnwrap(URL(string: text))
}

/// Дата из целого числа миллисекунд эпохи — выровнена по миллисекунде по построению.
func date(milliseconds: Int) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}

/// Тот же текст без ключа со значением `null`: отсутствующий ключ и явный `null` — одно
/// и то же значение `nil` (§0.4), и обе записи обязаны дать равные значения.
func withoutNullKey(_ text: String, _ key: String) -> String {
    text
        .replacingOccurrences(of: "\"\(key)\": null, ", with: "")
        .replacingOccurrences(of: ", \"\(key)\": null", with: "")
}

/// Тот же текст без ключа, значение которого — массив.
func withoutArrayKey(_ text: String, _ key: String) -> String {
    guard let head = text.range(of: "\"\(key)\": [") else { return text }
    var depth = 1
    var index = head.upperBound
    while index < text.endIndex, depth > 0 {
        switch text[index] {
        case "[": depth += 1
        case "]": depth -= 1
        default: break
        }
        index = text.index(after: index)
    }
    var lower = head.lowerBound
    var upper = index
    if text[upper...].hasPrefix(", ") {
        upper = text.index(upper, offsetBy: 2)
    } else if text[..<lower].hasSuffix(", ") {
        lower = text.index(lower, offsetBy: -2)
    }
    return text.replacingCharacters(in: lower..<upper, with: "")
}

/// Четыре структурных поля ошибки — единственное, что тесты вправе сравнивать.
struct ErrorFields: Equatable {
    let contract: String
    let type: String
    let invariant: Int
    let path: String
}

func errorFields<Value>(_ expression: @autoclosure () throws -> Value) -> ErrorFields? {
    do {
        _ = try expression()
        return nil
    } catch let failure as DomainValidationError {
        return ErrorFields(contract: failure.contract, type: failure.type,
                           invariant: failure.invariant, path: failure.path)
    } catch {
        return nil
    }
}

func validationError<Value>(_ expression: @autoclosure () throws -> Value) -> DomainValidationError? {
    do {
        _ = try expression()
        return nil
    } catch {
        return error as? DomainValidationError
    }
}
