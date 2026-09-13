//  DomainJSON — канонический вид байтов и отсекающие методы чтения чисел, C-001 §0.4.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Единственный санкционированный способ читать и писать форматы, чьи контракты назвали
//  `DomainJSON` своим способом чтения. Работает только с `Data`: файловых путей домен не знает.
//
//  Числа читаются нашим кодом, а не чужим: поведение разборщика на переполнении экспоненты
//  и на нецелом литерале в целочисленном поле не описано ни одним документом и вправе
//  отличаться между Darwin и swift-corelibs. Поэтому целые приходят числом и проверяются
//  здесь на конечность, целость, диапазон §0.2 п. 9 и диапазон объявленного типа.
//
//  Оба семейства объявлены расширениями `KeyedDecodingContainer`, а не `JSONDecoder`:
//  рукописный `init(from:)` у типа один, и тот же код исполняется на любом байтовом пути.

import Foundation

/// Канонический вид байтов C-001 §0.4.
public enum DomainJSON {

    /// Настроенный кодировщик для чужих API. Санкционированным способом писать наши файлы
    /// он не является (C-001 v11 §0.4): байтового прохода по ключам он не несёт — ровно та
    /// же граница, что у `decoder()` на чтении. `.sortedKeys` остаётся объявленным, и п. 110
    /// перечня стоит на нём дословно; порядок по UTF-8 обеспечивает `encode(_:)`.
    public static func encoder() -> JSONEncoder {
        let result = JSONEncoder()
        result.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        result.dateEncodingStrategy = .custom { date, encoder in
            guard let text = DomainDateGrammar.string(from: date) else {
                throw EncodingError.invalidValue(date, EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Date вне диапазона 0001-01-01…9999-12-31"))
            }
            var container = encoder.singleValueContainer()
            try container.encode(text)
        }
        return result
    }

    /// Настроенный разборщик для чужих API. Санкционированным способом чтения наших файлов
    /// он не является: байтовой проверки повторяющихся ключей он не несёт.
    public static func decoder() -> JSONDecoder {
        let result = JSONDecoder()
        result.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            guard let text = try? container.decode(String.self),
                  let date = DomainDateGrammar.date(from: text) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Отметка времени вне грамматики §0.4"))
            }
            return date
        }
        return result
    }

    /// Единственный санкционированный способ писать байты наших форматов: после кодирования
    /// вызывает `canonicalizeKeyOrder(in:)`. Проход даёт порядок ключей по UTF-8 на всякой
    /// сборке Foundation, а не только на той, где его даёт `.sortedKeys` (C-001 v11 §0.4).
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let bytes = try encoder().encode(value)
        return try canonicalizeKeyOrder(in: bytes)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try assertNoDuplicateKeys(in: data)
        return try decoder().decode(type, from: data)
    }
}

// MARK: - Чтение вещественных с проверкой конечности

extension KeyedDecodingContainer {

    public func decodeFinite(_ type: Double.Type, forKey key: Key) throws -> Double {
        let value = try decode(Double.self, forKey: key)
        guard value.isFinite else {
            throw domainCorrupted(key, "значение не представимо конечным Double")
        }
        return value
    }

    public func decodeFiniteIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        guard try domainPresent(key) else { return nil }
        return try decodeFinite(Double.self, forKey: key)
    }

    public func decodeFinite(_ type: [Float].Type, forKey key: Key) throws -> [Float] {
        var list = try nestedUnkeyedContainer(forKey: key)
        var result: [Float] = []
        while !list.isAtEnd {
            let raw: Double
            do {
                raw = try list.decode(Double.self)
            } catch {
                throw domainCorrupted(key, "элемент массива не представим конечным Float")
            }
            let narrowed = Float(raw)
            guard raw.isFinite, narrowed.isFinite else {
                throw domainCorrupted(key, "элемент массива не представим конечным Float")
            }
            result.append(narrowed)
        }
        return result
    }

    public func decodeFiniteIfPresent(_ type: [Float].Type, forKey key: Key) throws -> [Float]? {
        guard try domainPresent(key) else { return nil }
        return try decodeFinite([Float].self, forKey: key)
    }
}

// MARK: - Чтение целых с проверкой представимости

extension KeyedDecodingContainer {

    public func decodeBounded(_ type: Int.Type, forKey key: Key) throws -> Int {
        let value = try domainBounded(key, lower: -9_007_199_254_740_991, upper: 9_007_199_254_740_991)
        return Int(value)
    }

    public func decodeBoundedIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        guard try domainPresent(key) else { return nil }
        return try decodeBounded(Int.self, forKey: key)
    }

    public func decodeBounded(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        let value = try domainBounded(key, lower: Double(Int32.min), upper: Double(Int32.max))
        return Int32(value)
    }

    public func decodeBoundedIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? {
        guard try domainPresent(key) else { return nil }
        return try decodeBounded(Int32.self, forKey: key)
    }

    public func decodeBounded(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        let value = try domainBounded(key, lower: -9_007_199_254_740_991, upper: 9_007_199_254_740_991)
        return Int64(value)
    }

    public func decodeBoundedIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
        guard try domainPresent(key) else { return nil }
        return try decodeBounded(Int64.self, forKey: key)
    }

    /// Четыре условия §0.4: конечность, целость, диапазон §0.2 п. 9, диапазон объявленного типа.
    /// Все четыре дают одну и ту же ошибку с одним и тем же ключом — различие видно только в тексте.
    private func domainBounded(_ key: Key, lower: Double, upper: Double) throws -> Double {
        let raw = try decode(Double.self, forKey: key)
        guard raw.isFinite else {
            throw domainCorrupted(key, "значение не конечно")
        }
        guard raw == raw.rounded(.towardZero) else {
            throw domainCorrupted(key, "значение не целое")
        }
        guard raw >= -9_007_199_254_740_991, raw <= 9_007_199_254_740_991 else {
            throw domainCorrupted(key, "значение вне диапазона §0.2 п. 9")
        }
        guard raw >= lower, raw <= upper else {
            throw domainCorrupted(key, "значение вне диапазона объявленного типа поля")
        }
        return raw
    }

    private func domainPresent(_ key: Key) throws -> Bool {
        guard contains(key) else { return false }
        return try !decodeNil(forKey: key)
    }

    private func domainCorrupted(_ key: Key, _ reason: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: codingPath + [key],
            debugDescription: reason))
    }
}
