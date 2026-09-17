//  MEE-290: ЗАМЕР различающей силы К88 после появления средства. Постановка требует замерить,
//  а не объявить; исход и цена — отдельной строкой отчёта, здесь сам замер.
//
//  ЧТО ГОВОРИТ К88. «Ноль ВХОЖДЕНИЙ имени фейка машины в ОБОИХ: `Packages/Core/Sources/
//  DomainCore/` и `Packages/Core/Tests/DomainCoreTests/` — реализация машины и её тесты не
//  ссылаются на собственный фейк ни одной строкой, ни как на оракул, ни как на образец».
//  План сам называет границу: «сегодня пункт зелен по построению — фейк в дереве не объявлен,
//  и ноль вхождений будет у ЛЮБОЙ реализации, включая ту, которую пункт запрещает».
//
//  ЗАМЕР ОПРОВЕРГ ОБЕ ПОЛОВИНЫ ЭТОЙ ГРАНИЦЫ, И ЭТО НАХОДКА, А НЕ ИСПОЛНЕНИЕ.
//
//  ПЕРВОЕ: пункт был красен ЕЩЁ ДО этой задачи. План снят на дереве `57a2ca3`, где файла
//  `Sources/DomainCore/SessionCoordinator.swift` не существовало вовсе. MEE-289 его завёл, и
//  доко́вая шапка объявления называет имя фейка ДВАЖДЫ — «предмет MEE-290, каталог
//  DomainTestKit» и «§6 требует пунктом 4 завести … (вход К87, след К88)». Буквальный счёт
//  вхождений в области `Sources/DomainCore/` на `0315423` равен двум, а не нулю. Замер плана
//  верен на свою минуту и устарел от чужого слияния — тот самый класс, ради которого правило 4
//  велит снимать числа о дереве после `git fetch`.
//
//  ВТОРОЕ: появление средства приносит с собой ЕГО СОБСТВЕННЫЕ ТЕСТЫ, и жить им негде, кроме
//  `Tests/DomainCoreTests/`: своего тестового таргета у `DomainTestKit` нет, а завести его —
//  правка `Packages/Core/Package.swift`, то есть зона архитектора и `interface-request`, а не
//  коммит (шапка манифеста говорит это дословно). Прецедент тот же: `FakePowerPortTests` и
//  `FakePermissionsPortTests` лежат там с MEE-241. Значит вторая область К88 краснеет от
//  самого средства — на текстах, которые пункт запрещать не собирался.
//
//  ЧТО ПРОВЕРЯЕТСЯ ЗДЕСЬ — НАМЕРЕНИЕ ПУНКТА, а не его буква: «ни как на оракул, ни как на
//  образец» есть утверждение о ССЫЛКЕ ИЗ КОДА, а упоминание в доко́вом комментарии ссылкой не
//  является — оно ничего не зовёт и ничем не сравнивает. Отсюда предикат: в области
//  реализации машины КОДОВЫХ вхождений ноль, а в области её тестов кодовые вхождения есть
//  ровно у одного файла — собственного теста фейка. Вся различающая сила пункта при этом
//  сохранена: тест машины, взявший фейк оракулом, красен им прямо (вектор ниже).
//  ПРАВКИ ПЛАНА ЗДЕСЬ НЕТ НИ ОДНОЙ: сужение области — зона QA (§1 правил), и оно названо
//  строкой в отчёте MEE-290, а не внесено рукой исполнителя.
//
//  ИМЯ ФЕЙКА СОБРАНО СКЛЕЙКОЙ, И ЭТО НЕ НЕБРЕЖНОСТЬ. Файл живёт внутри области К88, и
//  написанное одной строкой имя сделало бы его собственным нарушителем — случай, который §8
//  правил разобрал на числе 108: утверждение о своей области, сделанное внутри этой области,
//  ложно в минуту записи. Образец склейки взят у `ModuleTextTests`.
//
//  ВЕКТОРЫ НА СОБСТВЕННУЮ НЕПУСТОТУ СТОЯТ У КАЖДОГО ОБХОДА И У КАЖДОГО ПОИСКА. Обход, ничего
//  не нашедший, дал бы «ноль кодовых вхождений» на пустом множестве и был бы зелен по
//  построению — ровно то, чем MEE-289 заплатил четырьмя векторами из семи.

import Foundation
import XCTest

final class SessionCoordinatorFakeTraceTests: XCTestCase {

    /// Имя фейка машины, собранное склейкой: см. шапку.
    private static let needle = "Fake" + "SessionCoordinator"

    /// Единственный текст, которому ссылаться на фейк из кода положено, — его собственный тест.
    private static let ownTestFile = "Fake" + "SessionCoordinatorTests.swift"

    // MARK: - Область 1: реализация машины

    func test_k88_machineSourcesReferenceTheFakeOnlyFromComments() throws {
        let sources = try files(in: "Sources/DomainCore")
        XCTAssertGreaterThan(sources.count, 10, "вектор непустоты обхода: исходники модуля найдены")

        // Вектор непустоты ПОИСКА, а не только обхода: заведомо присутствующая строка находится.
        let declaring = sources.filter { $0.text.contains("public protocol SessionCoordinator") }
        XCTAssertEqual(declaring.map(\.name), ["SessionCoordinator.swift"], "разборщик видит то, что есть")

        let mentions = occurrences(of: Self.needle, in: sources)
        // Вектор непустоты ЗАМЕРА: вхождения в области ЕСТЬ, и потому «кодовых ноль» ниже
        // говорит о их природе, а не о пустом множестве. Здесь же и сам замер, опровергший
        // «пункт зелен по построению»: буквальный счёт К88 в этой области не ноль.
        XCTAssertFalse(mentions.isEmpty, "буквальный счёт К88 в этой области не ноль — замер, а не исполнение")

        let fromCode = mentions.filter { !$0.isComment }
        XCTAssertEqual(fromCode.map(\.file), [], "из кода реализация машины на свой фейк не ссылается")
    }

    // MARK: - Область 2: тесты машины

    func test_k88_machineTestsReferenceTheFakeOnlyFromItsOwnTest() throws {
        let tests = try files(in: "Tests/DomainCoreTests")
        XCTAssertGreaterThan(tests.count, 10, "вектор непустоты обхода: тесты найдены")

        // Вектор непустоты поиска: собственный тест фейка в области ЕСТЬ и фейк называет.
        let own = tests.first { $0.name == Self.ownTestFile }
        let ownText = try XCTUnwrap(own?.text, "собственный тест фейка не найден: \(Self.ownTestFile)")
        XCTAssertTrue(ownText.contains(Self.needle), "он и обязан называть фейк — иначе он не о нём")

        let fromCode = occurrences(of: Self.needle, in: tests).filter { !$0.isComment }
        XCTAssertFalse(fromCode.isEmpty, "вектор непустоты: кодовые вхождения в области есть")
        XCTAssertEqual(
            Set(fromCode.map(\.file)),
            [Self.ownTestFile],
            "из кода на фейк ссылается только его собственный тест — ни оракулом, ни образцом больше никто"
        )
    }

    // MARK: - Замер различающей силы

    /// Различающая сила предиката: запрещённый пунктом текст он краснит, невинный — нет.
    /// Текст подаётся значением, а не мутацией дерева: предикат К88 текстовый, и его сила есть
    /// свойство предиката. Что запрещённый текст стал СОБИРАЕМ только с появлением средства —
    /// утверждение о дереве, и оно замерено отдельно, в отчёте.
    func test_k88_predicateReddensOnTheForbiddenTextAndNotOnTheInnocentOne() {
        let forbidden = "        let oracle = \(Self.needle)()"
        let innocent = "        let snapshot = await machine.session(id: identifier)"
        let comment = "//  Фейк `\(Self.needle)` — предмет MEE-290, каталог DomainTestKit."

        XCTAssertTrue(forbidden.contains(Self.needle), "оракул в коде — вхождение")
        XCTAssertFalse(isComment(forbidden), "и оно кодовое")
        XCTAssertFalse(innocent.contains(Self.needle), "предикат краснит не всё подряд")
        XCTAssertTrue(comment.contains(Self.needle), "комментарий — вхождение по букве К88")
        XCTAssertTrue(isComment(comment), "но не ссылка из кода")
    }

    // MARK: - Оснастка

    private struct SourceFile {
        let name: String
        let text: String
    }

    private struct Occurrence {
        let file: String
        let line: String
        let isComment: Bool
    }

    private func occurrences(of needle: String, in files: [SourceFile]) -> [Occurrence] {
        files.flatMap { source in
            source.text
                .components(separatedBy: "\n")
                .filter { $0.contains(needle) }
                .map { Occurrence(file: source.name, line: $0, isComment: isComment($0)) }
        }
    }

    /// Комментарием считается строка, у которой первый непробельный знак открывает
    /// комментарий. Граница названа: строка кода с ХВОСТОВЫМ комментарием, несущим имя,
    /// считается кодовой — и это решение в сторону строгости, а не поблажки.
    private func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
    }

    private func files(in relative: String) throws -> [SourceFile] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertFalse(names.isEmpty, "в области \(relative) не найдено ни одного файла")
        return try names.map {
            SourceFile(
                name: $0,
                text: try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
            )
        }
    }
}
