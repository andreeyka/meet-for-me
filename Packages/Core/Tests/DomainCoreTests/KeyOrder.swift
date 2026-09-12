//  Порядок ключей в каноническом тексте: разбор записи в списки ключей каждого объекта.
//
//  Пункт 109 требует сравнивать список ключей каждого объекта на каждом уровне с его
//  отсортированной копией, а `JSONSerialization` порядок ключей при чтении теряет —
//  поэтому порядок снимается с текста, а не с разобранного значения.

import XCTest

/// Списки ключей всех объектов текста, каждый — в порядке записи, сверху вниз.
struct KeyOrderScanner {

    private var lists: [[String]] = []
    private var open: [Int?] = []
    private var pendingKey: String?
    private var expectKey = false

    static func objectKeyLists(in text: String) -> [[String]] {
        var scanner = KeyOrderScanner()
        scanner.scan(text)
        return scanner.lists
    }

    private mutating func scan(_ text: String) {
        var inString = false
        var escaped = false
        var buffer = ""
        for character in text {
            if inString {
                inString = consume(character, into: &buffer, escaped: &escaped)
            } else if character == "\"" {
                inString = true
                escaped = false
                buffer = ""
            } else {
                structural(character)
            }
        }
    }

    /// Возвращает `true`, пока строковый литерал не закрыт.
    private mutating func consume(_ character: Character, into buffer: inout String,
                                  escaped: inout Bool) -> Bool {
        if escaped {
            buffer.append(character)
            escaped = false
            return true
        }
        if character == "\\" {
            escaped = true
            return true
        }
        if character == "\"" {
            if expectKey {
                pendingKey = buffer
            }
            return false
        }
        buffer.append(character)
        return true
    }

    private mutating func structural(_ character: Character) {
        switch character {
        case "{":
            lists.append([])
            open.append(lists.count - 1)
            expectKey = true
        case "[":
            open.append(nil)
            expectKey = false
        case "}", "]":
            if !open.isEmpty {
                open.removeLast()
            }
            expectKey = false
        case ":":
            appendPendingKey()
            expectKey = false
        case ",":
            expectKey = (open.last ?? nil) != nil
        default:
            break
        }
    }

    private mutating func appendPendingKey() {
        guard let index = open.last ?? nil, let key = pendingKey else { return }
        lists[index].append(key)
        pendingKey = nil
    }
}

/// Ключи каждого объекта текста совпадают со своей отсортированной по UTF-8 копией.
func assertKeysSortedRecursively(_ text: String, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
    let lists = KeyOrderScanner.objectKeyLists(in: text)
    XCTAssertFalse(lists.isEmpty, "\(label): объектов не найдено", file: file, line: line)
    XCTAssertTrue(lists.contains { $0.count > 1 }, "\(label): сравнивать нечего",
                  file: file, line: line)
    for keys in lists {
        let sorted = keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        XCTAssertEqual(keys, sorted, "\(label): ключи объекта не отсортированы",
                       file: file, line: line)
    }
}
