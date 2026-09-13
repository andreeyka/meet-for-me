//  П. 155: граница члена `DomainJSON`, отдающего настроенный `JSONEncoder`, на записи.
//  Санкционированным способом писать наши файлы он с издания C-001 v11 не является —
//  ровно та же граница, что у `decoder` на чтении (п. 14, свойство (г)).
//
//  Способ Т плана MEE-126 — текстовая проверка по исходникам, исполняемая как тест; тот
//  же, каким в этом таргете живут текстовые половины К63, К64 и К66 (`ModuleTextTests`).
//
//  ОБЛАСТЬ — `Packages/Core/Sources` и `Packages/Core/Tests` целиком, без единого изъятия:
//  ни `--exclude`, ни фильтра по имени файла, ни изъятия файла самой этой проверки. Ровно
//  в нём вхождение и спрячется. Область шире модуля: из файлов дерева двенадцать
//  принадлежат чужим модулям, и красное, вызванное их файлом, чинится их владельцем (П1).
//
//  ВСЯКИЙ образец с искомым написанием собран здесь из частей — и в коде, и в комментариях.
//  Записанный одним литералом, он сам есть вхождение вне всех четырёх классов и красит
//  пункт на верном тесте верной реализации. Форма та же, что у п. 96 (а)
//  (`ModuleTextTests.swift:51`), охват больше: написание содержат образцы ВСЕХ ЧЕТЫРЁХ
//  классов, включая образец класса (1) — объявление самого члена.
//
//  Классы опознаются парой «написание + охватывающая единица», и единица — метод или тело
//  функции, НИКОГДА файл: класс, названный файлом, вывел бы этот файл из-под проверки.
//  Квалификатор `DomainJSON.` при этом различает классы, а не задаёт область поиска:
//  классы (1) и (2) стоят без него, и проверка, ищущая только квалифицированное написание,
//  покраснела бы на верном дереве.
//
//  Что пункт доказывает и чего не доказывает — та же граница, что у команды Б33 и у пяти
//  текстовых половин в этом же таргете: он доказывает отсутствие НАПИСАНИЯ, а не отсутствие
//  действия. Вхождение, собранное из переменной или склейки, проходит и его, и команду.
//  Вторая граница названа здесь же: охватывающая единица берётся по последней строке с
//  объявлением функции выше по файлу — так же, как её берёт разбор в команде Б31.

import XCTest
import Foundation
import DomainCore

final class EncoderBoundaryTests: XCTestCase {

    /// Искомое написание, собранное из частей: литералом оно было бы вхождением вне всех
    /// классов и покрасило бы собственный пункт. Все четыре образца выведены из него.
    private static let spelling = "encoder" + "()"

    /// Множество вхождений в области, не подпавших НИ ПОД ОДИН класс, — пусто. Красным
    /// пункт делает такое вхождение, а не порядковый номер вхождения: число вхождений
    /// внутри класса не ограничено ничем.
    func test_p155_encoderOccurrences_areAllInOneOfFourClasses() throws {
        let sources = try areaSources()
        XCTAssertFalse(sources.isEmpty, "область пуста — проверка была бы зелёной по построению")
        var declarationsFound = 0
        for source in sources {
            var unit = ""
            for (offset, line) in source.lines.enumerated() {
                if let name = Self.functionName(in: line) {
                    unit = name
                }
                let total = Self.count(Self.spelling, in: line)
                guard total > 0 else { continue }
                let legal = Self.classify(line, unit: unit, declaresDomainJSON: source.declaresDomainJSON)
                declarationsFound += legal.declarations
                XCTAssertGreaterThanOrEqual(legal.total, total,
                                            "\(source.name):\(offset + 1) — вхождение вне всех "
                                            + "четырёх классов, охватывающая единица «\(unit)»")
            }
        }
        //  Непустота области утверждается отдельно, а не предполагается: объявление члена
        //  обязано существовать — сигнатуру объявляет C-001 §0.4 swift-блоком, и на неё же
        //  стоит п. 110. Ноль найденных объявлений — это либо сломанная область, либо
        //  снятое объявление, и оба исхода красные.
        XCTAssertGreaterThan(declarationsFound, 0,
                             "класс (1) в области не найден: область сломана или объявление снято")
    }

    /// Охват области — отдельным утверждением, потому что признак внешний: путь считается
    /// от `#filePath`, и сломанный путь даёт ноль файлов, ноль вхождений и зелёное на любом
    /// дереве, включая дерево нарушителя.
    func test_p155_encoderOccurrences_areaCoversBothDirectoriesWholly() throws {
        let sources = try areaSources()
        XCTAssertTrue(sources.contains { $0.name.hasPrefix("Sources/") }, "каталог Sources не прочитан")
        XCTAssertTrue(sources.contains { $0.name.hasPrefix("Tests/") }, "каталог Tests не прочитан")
        XCTAssertTrue(sources.contains { $0.declaresDomainJSON }, "файл, объявляющий DomainJSON, не найден")
        //  Изъятий нет ни одного: файл самой проверки просматривается наравне с прочими,
        //  и каталоги чужих модулей — тоже.
        XCTAssertTrue(sources.contains { $0.name.hasSuffix("/EncoderBoundaryTests.swift") },
                      "файл самой проверки изъят из области")
        let modules = Set(sources.compactMap { Self.moduleName(of: $0.name) })
        XCTAssertGreaterThan(modules.count, 2, "область сужена до модуля — изъятий быть не должно")
        //  МУТАЦИЯ L1 (вектор Q43): вхождение вне всех четырёх классов, стоящее в файле
        //  самой проверки. Пункт 155 обязан покраснеть в обеих работах.
        _ = try? DomainJSON.encoder().encode(["mutation": 1])
    }

    // MARK: - Классификация

    /// Сколько вхождений строки подпадает под классы и сколько из них — класс (1).
    private static func classify(_ line: String, unit: String,
                                 declaresDomainJSON: Bool) -> LegalOccurrences {
        var declarations = 0
        var total = 0
        if declaresDomainJSON {
            declarations = count("public static func " + spelling + " -> JSONEncoder", in: line)
            total += declarations
            if unit == "encode" {
                total += count("try " + spelling + ".encode(", in: line)
            }
        }
        if unit.hasPrefix("test_p110_") {
            total += count("DomainJSON." + spelling + ".outputFormatting", in: line)
        }
        if unit.hasPrefix("test_p154_") {
            total += count("canonicalizeKeyOrder(in: DomainJSON." + spelling, in: line)
        }
        return LegalOccurrences(total: total, declarations: declarations)
    }

    // MARK: - Оснастка: чтение области

    private func areaSources() throws -> [AreaSource] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var result: [AreaSource] = []
        for directory in ["Sources", "Tests"] {
            let base = root.appendingPathComponent(directory)
            let paths = try FileManager.default.subpathsOfDirectory(atPath: base.path)
                .filter { $0.hasSuffix(".swift") }
                .sorted()
            for path in paths {
                let text = try String(contentsOf: base.appendingPathComponent(path),
                                      encoding: .utf8)
                result.append(AreaSource(name: "\(directory)/\(path)", text: text))
            }
        }
        return result
    }

    private static func moduleName(of path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 2 else { return nil }
        return String(parts[1])
    }

    /// Число вхождений подстроки в строке: классификация считает вхождения, а не строки,
    /// иначе законное вхождение прикрыло бы незаконное, стоящее рядом с ним.
    private static func count(_ needle: String, in line: String) -> Int {
        var total = 0
        var rest = Substring(line)
        while let found = rest.range(of: needle) {
            total += 1
            rest = rest[found.upperBound...]
        }
        return total
    }

    /// Имя функции или метода, объявленного этой строкой: охватывающая единица для строк
    /// ниже по файлу.
    private static func functionName(in line: String) -> String? {
        guard let marker = line.range(of: "func ") else { return nil }
        let name = line[marker.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

private struct LegalOccurrences {
    let total: Int
    let declarations: Int
}

private struct AreaSource {

    let name: String
    let text: String

    var lines: [String] {
        text.components(separatedBy: "\n")
    }

    var declaresDomainJSON: Bool {
        text.contains("public enum DomainJSON")
    }
}
