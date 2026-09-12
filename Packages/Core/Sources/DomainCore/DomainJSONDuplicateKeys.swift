//  Байтовый пре-проход по документу: объект с повторённым ключом отвергается, C-001 §0.4.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  RFC 8259 §4 такой объект допускает и оставляет исход реализации: одна возьмёт первое
//  значение, другая последнее, третья откажет. Контракт выбирает отказ, и обеспечивается он
//  здесь, а не сборкой Foundation, — иначе «один и тот же тест зелёный в обеих работах CI»
//  перестало бы быть верным. Проход линейный, значения не разбираются.

import Foundation

extension DomainJSON {

    /// Отвергает объект, в котором один и тот же ключ встречается дважды.
    /// Бросает `DecodingError.dataCorrupted`, в `codingPath` которого стоит путь до ключа.
    public static func assertNoDuplicateKeys(in data: Data) throws {
        var scanner = DuplicateKeyScanner(bytes: [UInt8](data))
        try scanner.run()
    }
}

/// Ключ пути, собранный байтовым проходом: имя поля либо индекс элемента массива.
private struct ScannedKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }
}

private enum FrameKind {
    case object
    case array
}

private struct Frame {
    let kind: FrameKind
    var keys: Set<String> = []
    var currentKey: String?
    var index = 0
}

/// Лексер строк, а не поиск подстроки: текст, похожий на повторённый ключ, внутри
/// строкового значения повторением не является и отказа не даёт.
private struct DuplicateKeyScanner {
    let bytes: [UInt8]
    var index = 0
    var frames: [Frame] = []
    var awaitingKey = false

    mutating func run() throws {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case 0x7B:
                frames.append(Frame(kind: .object))
                awaitingKey = true
                index += 1
            case 0x5B:
                frames.append(Frame(kind: .array))
                awaitingKey = false
                index += 1
            case 0x7D, 0x5D:
                closeFrame()
            case 0x3A:
                awaitingKey = false
                index += 1
            case 0x2C:
                advanceAfterComma()
            case 0x22:
                try readString()
            default:
                skipLiteral()
            }
        }
    }

    private mutating func closeFrame() {
        if !frames.isEmpty {
            frames.removeLast()
        }
        awaitingKey = false
        index += 1
    }

    private mutating func advanceAfterComma() {
        if let last = frames.indices.last {
            if frames[last].kind == .object {
                awaitingKey = true
            } else {
                frames[last].index += 1
            }
        }
        index += 1
    }

    private mutating func readString() throws {
        let text = scanString()
        guard awaitingKey, let last = frames.indices.last, frames[last].kind == .object else { return }
        guard !frames[last].keys.contains(text) else { throw duplicate(text) }
        frames[last].keys.insert(text)
        frames[last].currentKey = text
    }

    private mutating func scanString() -> String {
        index += 1
        var raw: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C {
                raw.append(byte)
                index += 1
                if index < bytes.count {
                    raw.append(bytes[index])
                    index += 1
                }
                continue
            }
            index += 1
            if byte == 0x22 {
                break
            }
            raw.append(byte)
        }
        return String(bytes: raw, encoding: .utf8) ?? ""
    }

    private mutating func skipLiteral() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D:
                return
            default:
                index += 1
            }
        }
    }

    private func duplicate(_ key: String) -> DecodingError {
        var path: [CodingKey] = []
        for position in frames.indices.dropLast() {
            let frame = frames[position]
            switch frame.kind {
            case .object:
                if let currentKey = frame.currentKey {
                    path.append(ScannedKey(stringValue: currentKey))
                }
            case .array:
                path.append(ScannedKey(intValue: frame.index))
            }
        }
        path.append(ScannedKey(stringValue: key))
        return DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: path,
            debugDescription: "Ключ \"\(key)\" встречается в объекте дважды"))
    }
}
