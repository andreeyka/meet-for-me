//  Байтовый проход после кодирования: ключи каждого объекта переставляются в порядок
//  по UTF-8, C-001 v11 §0.4.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Механизм этого класса в модуле третий — после `assertNoDuplicateKeys(in:)` и обоих
//  семейств отсекающих методов, — и довод у него тот же: исход не вправе зависеть от
//  сборки Foundation. Отличие названо контрактом: там наш код стоит ДО чужого, здесь —
//  ПОСЛЕ. `.sortedKeys` на macos-14 упорядочивает ключи без учёта регистра, и во всей
//  схеме C-001…C-003 пара `captureGroupKey` / `capturedProcesses` — единственная, где
//  разница видна (измерено 12.09, коммит 1da0772, IR-087).
//
//  Разбор двухфазный, и это решение по цене: первая фаза размечает документ границами
//  байтов, не копируя ни одного, вторая пишет их в один буфер. Так каждый байт выхода
//  копируется ровно один раз — проход линеен по длине входа, и §0.2 п. 7 не нарушен.
//
//  Пары переставляются целиком: ни один байт внутри ключа и внутри значения не меняется.
//  Пробельные байты МЕЖДУ лексемами — структура, а не содержимое ключа или значения:
//  выход всегда компактен. На входе из `encode(_:)` — выводе собственного кодировщика —
//  их нет вовсе, поэтому там проход не меняет ничего, кроме взаимного положения пар.

import Foundation

extension DomainJSON {

    /// Перекладывает ключи каждого объекта в порядок по UTF-8, рекурсивно на всех уровнях.
    /// Вызывается из `encode(_:)` после кодирования; один проход по байтам. Пары «ключ:
    /// значение» переставляются целиком, порядок элементов массива не трогается.
    /// На байтах, не являющихся документом JSON, бросает `DecodingError.dataCorrupted`
    /// с пустым `codingPath`; из `encode(_:)` эта ветвь недостижима — на входе там вывод
    /// собственного кодировщика.
    public static func canonicalizeKeyOrder(in data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var reader = KeyOrderReader(bytes: bytes)
        let document = try reader.readDocument()
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        KeyOrderWriter(bytes: bytes).write(document, into: &output)
        return Data(output)
    }
}

// MARK: - Разметка документа

/// Размеченное значение: названо границами байтов входа, ни один байт не скопирован.
private indirect enum KeyOrderNode {
    case scalar(Range<Int>)
    case array([KeyOrderNode])
    case object([KeyOrderMember])
}

/// Пара «ключ: значение» объекта. `order` — октеты UTF-8-записи ключа, по которым
/// пары и упорядочиваются; `key` — байты записи JSON, которые уйдут в выход как есть.
private struct KeyOrderMember {
    let key: Range<Int>
    let order: [UInt8]
    let value: KeyOrderNode
}

/// Отказ ровно один: вход не является документом JSON. `codingPath` пуст — §0.4 дословно.
private func keyOrderCorrupted() -> DecodingError {
    DecodingError.dataCorrupted(DecodingError.Context(
        codingPath: [],
        debugDescription: "Байты не являются документом JSON"))
}

// MARK: - Первая фаза: чтение

private struct KeyOrderReader {

    let bytes: [UInt8]
    var index = 0

    mutating func readDocument() throws -> KeyOrderNode {
        let document = try readValue()
        skipWhitespace()
        guard index == bytes.count else { throw keyOrderCorrupted() }
        return document
    }

    private mutating func readValue() throws -> KeyOrderNode {
        skipWhitespace()
        guard let byte = current else { throw keyOrderCorrupted() }
        switch byte {
        case 0x7B:
            return try readObject()
        case 0x5B:
            return try readArray()
        case 0x22:
            return .scalar(try readString())
        default:
            return .scalar(try readLiteral())
        }
    }

    private mutating func readObject() throws -> KeyOrderNode {
        index += 1
        skipWhitespace()
        if current == 0x7D {
            index += 1
            return .object([])
        }
        var members: [KeyOrderMember] = []
        while true {
            members.append(try readMember())
            skipWhitespace()
            guard let byte = current else { throw keyOrderCorrupted() }
            index += 1
            if byte == 0x7D {
                break
            }
            guard byte == 0x2C else { throw keyOrderCorrupted() }
        }
        return .object(sortedByKey(members))
    }

    private mutating func readMember() throws -> KeyOrderMember {
        skipWhitespace()
        guard current == 0x22 else { throw keyOrderCorrupted() }
        let key = try readString()
        skipWhitespace()
        guard current == 0x3A else { throw keyOrderCorrupted() }
        index += 1
        let order = try orderKey(key)
        let value = try readValue()
        return KeyOrderMember(key: key, order: order, value: value)
    }

    private mutating func readArray() throws -> KeyOrderNode {
        index += 1
        skipWhitespace()
        if current == 0x5D {
            index += 1
            return .array([])
        }
        var items: [KeyOrderNode] = []
        while true {
            items.append(try readValue())
            skipWhitespace()
            guard let byte = current else { throw keyOrderCorrupted() }
            index += 1
            if byte == 0x5D {
                break
            }
            guard byte == 0x2C else { throw keyOrderCorrupted() }
        }
        return .array(items)
    }

    private mutating func readString() throws -> Range<Int> {
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
                return start..<index
            }
        }
        throw keyOrderCorrupted()
    }

    private mutating func readLiteral() throws -> Range<Int> {
        for word in ["true", "false", "null"] where matches(word) {
            let start = index
            index += word.utf8.count
            return start..<index
        }
        return try readNumber()
    }

    private mutating func readNumber() throws -> Range<Int> {
        let start = index
        if current == 0x2D {
            index += 1
        }
        try readIntegerPart()
        try readFractionPart()
        try readExponentPart()
        return start..<index
    }

    private mutating func readIntegerPart() throws {
        guard let first = current, isDigit(first) else { throw keyOrderCorrupted() }
        if first == 0x30 {
            index += 1
            return
        }
        skipDigits()
    }

    private mutating func readFractionPart() throws {
        guard current == 0x2E else { return }
        index += 1
        guard let digit = current, isDigit(digit) else { throw keyOrderCorrupted() }
        skipDigits()
    }

    private mutating func readExponentPart() throws {
        guard current == 0x65 || current == 0x45 else { return }
        index += 1
        if current == 0x2B || current == 0x2D {
            index += 1
        }
        guard let digit = current, isDigit(digit) else { throw keyOrderCorrupted() }
        skipDigits()
    }

    /// Ключ сравнивается октетами своей UTF-8-ЗАПИСИ, а не байтами записи JSON:
    /// ключ, записанный экранированием вида `\uXXXX`, и ключ, записанный самой буквой, —
    /// один и тот же ключ. Экранирований в ключах наших форматов нет, поэтому быстрый
    /// путь — байты как есть, и на таком ключе он даёт ровно то же, что разбор.
    private func orderKey(_ range: Range<Int>) throws -> [UInt8] {
        let inner = (range.lowerBound + 1)..<(range.upperBound - 1)
        let raw = Array(bytes[inner])
        guard raw.contains(0x5C) else { return raw }
        return try unescapeJSONString(raw)
    }

    /// Устойчивая сортировка: при равных ключах порядок входа сохраняется, иначе
    /// повторённый ключ (его отвергает `assertNoDuplicateKeys(in:)`, но не этот проход)
    /// ломал бы идемпотентность.
    private func sortedByKey(_ members: [KeyOrderMember]) -> [KeyOrderMember] {
        members.enumerated().sorted { lhs, rhs in
            if lhs.element.order == rhs.element.order {
                return lhs.offset < rhs.offset
            }
            return lhs.element.order.lexicographicallyPrecedes(rhs.element.order)
        }.map(\.element)
    }

    private mutating func skipDigits() {
        while let byte = current, isDigit(byte) {
            index += 1
        }
    }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private func matches(_ word: String) -> Bool {
        let pattern = [UInt8](word.utf8)
        guard index + pattern.count <= bytes.count else { return false }
        return Array(bytes[index..<(index + pattern.count)]) == pattern
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}

// MARK: - Разбор экранирований: только ради порядка, в выход эти байты не идут

private func unescapeJSONString(_ raw: [UInt8]) throws -> [UInt8] {
    var result: [UInt8] = []
    var index = 0
    while index < raw.count {
        let byte = raw[index]
        index += 1
        guard byte == 0x5C else {
            result.append(byte)
            continue
        }
        guard index < raw.count else { throw keyOrderCorrupted() }
        let code = raw[index]
        index += 1
        if code == 0x75 {
            let scalar = try unescapeUnicode(raw, at: &index)
            result.append(contentsOf: scalar)
            continue
        }
        guard let plain = shortEscape(code) else { throw keyOrderCorrupted() }
        result.append(plain)
    }
    return result
}

private func shortEscape(_ code: UInt8) -> UInt8? {
    switch code {
    case 0x22, 0x5C, 0x2F:
        return code
    case 0x62:
        return 0x08
    case 0x66:
        return 0x0C
    case 0x6E:
        return 0x0A
    case 0x72:
        return 0x0D
    case 0x74:
        return 0x09
    default:
        return nil
    }
}

private func unescapeUnicode(_ raw: [UInt8], at index: inout Int) throws -> [UInt8] {
    let first = try hexQuad(raw, at: &index)
    var value = UInt32(first)
    if first >= 0xD800, first <= 0xDBFF {
        guard index + 1 < raw.count, raw[index] == 0x5C, raw[index + 1] == 0x75 else {
            throw keyOrderCorrupted()
        }
        index += 2
        let low = try hexQuad(raw, at: &index)
        guard low >= 0xDC00, low <= 0xDFFF else { throw keyOrderCorrupted() }
        value = 0x10000 + (UInt32(first - 0xD800) << 10) + UInt32(low - 0xDC00)
    }
    guard let scalar = Unicode.Scalar(value) else { throw keyOrderCorrupted() }
    return [UInt8](String(scalar).utf8)
}

private func hexQuad(_ raw: [UInt8], at index: inout Int) throws -> UInt16 {
    guard index + 4 <= raw.count else { throw keyOrderCorrupted() }
    var value: UInt16 = 0
    for _ in 0..<4 {
        guard let digit = hexDigit(raw[index]) else { throw keyOrderCorrupted() }
        value = value << 4 | digit
        index += 1
    }
    return value
}

private func hexDigit(_ byte: UInt8) -> UInt16? {
    switch byte {
    case 0x30...0x39:
        return UInt16(byte - 0x30)
    case 0x41...0x46:
        return UInt16(byte - 0x41 + 10)
    case 0x61...0x66:
        return UInt16(byte - 0x61 + 10)
    default:
        return nil
    }
}

// MARK: - Вторая фаза: запись

/// Размеченный документ пишется в один буфер, каждый байт копируется ровно однажды.
private struct KeyOrderWriter {

    let bytes: [UInt8]

    func write(_ node: KeyOrderNode, into output: inout [UInt8]) {
        switch node {
        case .scalar(let range):
            output.append(contentsOf: bytes[range])
        case .array(let items):
            output.append(0x5B)
            for (position, item) in items.enumerated() {
                if position > 0 {
                    output.append(0x2C)
                }
                write(item, into: &output)
            }
            output.append(0x5D)
        case .object(let members):
            output.append(0x7B)
            for (position, member) in members.enumerated() {
                if position > 0 {
                    output.append(0x2C)
                }
                output.append(contentsOf: bytes[member.key])
                output.append(0x3A)
                write(member.value, into: &output)
            }
            output.append(0x7D)
        }
    }
}
