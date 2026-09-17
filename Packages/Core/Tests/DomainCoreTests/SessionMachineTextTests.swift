//  Текстовые пункты по исходникам — К4, К9, К19 (текстовая половина), К27,
//  К28 (текстовая половина), К54, К83. Способ `Й` плана MEE-288 §1.
//  MEE-298, часть A.
//
//  ОБЛАСТЬ ПУТЕВАЯ — ЭТО И ЕСТЬ УСЛОВИЕ `Т` ПЛАНА §2, И ПРИЗНАК У НЕЁ ОДИН И МЕХАНИЧЕСКИЙ:
//  пути машины — файлы `Sources/DomainCore/SessionMachine*.swift` вместе с объявлениями
//  `SessionCoordinator.swift`. Отделимость создаёт реализация, и создана она именем файла,
//  а не соглашением о комментарии: соглашение проверяется чтением, имя — прогоном.
//
//  ГРАНИЦА ВСЕХ ПУНКТОВ ЭТОГО ФАЙЛА НАЗВАНА, А НЕ УМОЛЧАНА (§5 п. 7 плана): они доказывают
//  отсутствие НАПИСАНИЯ, а не отсутствие поведения. Литерал, собранный склейкой, и `Date()`,
//  спрятанный за вычисляемым свойством в постороннем файле модуля, их проходят.
//
//  ВЕКТОРЫ НА СОБСТВЕННУЮ НЕПУСТОТУ СТОЯТ У КАЖДОГО ОБХОДА И У КАЖДОГО ПОИСКА: обход,
//  ничего не нашедший, дал бы «ноль вхождений» на пустом множестве и был бы зелен по
//  построению.

import Foundation
import XCTest

final class SessionMachineTextTests: XCTestCase {

    private struct SourceFile {
        let name: String
        let text: String
    }

    /// Пути машины — путевая область условия `Т`.
    private func machineFiles() throws -> [SourceFile] {
        let all = try files(in: "Sources/DomainCore")
        let mine = all.filter { $0.name.hasPrefix("SessionMachine") || $0.name == "SessionCoordinator.swift" }
        XCTAssertGreaterThanOrEqual(mine.count, 5, "вектор непустоты: путевая область не пуста")
        XCTAssertTrue(
            mine.contains { $0.text.contains("public actor SessionMachine") },
            "вектор непустоты поиска: реализация машины в области ЕСТЬ"
        )
        XCTAssertLessThan(mine.count, all.count, "и область у́же сплошной — иначе условие `Т` не исполнено")
        return mine
    }

    // MARK: - К4 (инв. 1; §1.2)

    /// Ноль объявлений перечисления, чей набор сырых значений совпадает с `MeetingStatus`
    /// целиком ИЛИ содержит хотя бы семь из девяти его имён; ноль функций отображения между
    /// двумя перечислениями состояний. Область СПЛОШНАЯ: второе перечисление опасно в любом
    /// файле модуля, а не только на путях машины.
    func test_k4_noSecondEnumerationOfSessionStates() throws {
        let names: Set<String> = ["scheduled", "armed", "awaitingSignal", "recording",
                                  "stopping", "processing", "ready", "failed", "skipped"]
        let sources = try files(in: "Sources/DomainCore")
        var hits: [String: Int] = [:]
        for source in sources {
            let declared = source.text
                .components(separatedBy: "\n")
                .filter { !isComment($0) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("case ") }
                .flatMap { caseNames(in: $0) }
            let overlap = names.intersection(declared).count
            if overlap > 0 { hits[source.name] = overlap }
        }
        XCTAssertFalse(hits.isEmpty, "вектор непустоты: объявления случаев в модуле разобраны")
        XCTAssertEqual(
            hits.filter { $0.value >= 7 }.keys.sorted(),
            ["Repositories.swift"],
            "набор из семи и более имён `MeetingStatus` объявлен ровно в одном файле — чужом (C-010)"
        )
        XCTAssertEqual(hits["Repositories.swift"], 9, "и там он полон — это и есть единственное перечисление")

        // Ноль функций отображения между двумя перечислениями состояний. ПРИЗНАК ОТОБРАЖЕНИЯ —
        // чужое перечисление НА ВХОДЕ, а не состояние на выходе: состояние на выходе даёт
        // всякая строка таблицы §7, и грубый признак «возвращает `MeetingStatus`» красил в
        // прогоне 146 строку 1 (`openingState(event:settings:now:)`), то есть саму машину.
        // Различающая сила сохранена: `func state(from: RecordingState) -> MeetingStatus`
        // этим признаком ловится.
        let producing = try machineFiles().flatMap { source in
            source.text.components(separatedBy: "\n")
                .filter { $0.contains("func ") && $0.contains("-> MeetingStatus") && !isComment($0) }
                .map { "\(source.name): \($0.trimmingCharacters(in: .whitespaces))" }
        }
        XCTAssertFalse(producing.isEmpty, "вектор непустоты: функции, дающие состояние, в области есть")
        let mapping = producing.filter { takesForeignStateType($0) }
        XCTAssertEqual(mapping, [], "функции, переводящей чужое перечисление в `MeetingStatus`, нет")
    }

    /// Стоит ли среди параметров строки объявления тип, чьё имя кончается на `State` или
    /// `Status` и не есть `MeetingStatus`. Это и есть признак отображения между двумя
    /// перечислениями состояний.
    private func takesForeignStateType(_ line: String) -> Bool {
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else {
            return false
        }
        let parameters = String(line[line.index(after: open)..<close])
        return parameters
            .components(separatedBy: CharacterSet(charactersIn: " ,:()[]?<>-"))
            .contains { $0.hasSuffix("State") || ($0.hasSuffix("Status") && $0 != "MeetingStatus") }
    }

    /// Имена случаев из строки объявления: `case a, b(x), c` → `["a", "b", "c"]`.
    private func caseNames(in line: String) -> [String] {
        line.dropFirst("case ".count)
            .components(separatedBy: ",")
            .map { part -> String in
                let head = part.trimmingCharacters(in: .whitespaces)
                return String(head.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - К9 (§4; «Что вне контракта»: собственных часов нет)

    /// Ноль вхождений десяти имён на путях машины; всякий метод, которому нужен «сейчас»,
    /// несёт `now: Date` параметром.
    func test_k9_noClocksNoTimersNoSleepOnTheMachinePaths() throws {
        let forbidden = [
            "Date()", "Date.now", "Timer", "asyncAfter", "DispatchSourceTimer",
            "Task.sleep", "ContinuousClock", "SuspendingClock",
            "CFAbsoluteTimeGetCurrent", "mach_absolute_time"
        ]
        let sources = try machineFiles()
        for needle in forbidden {
            let hits = sources.flatMap { source in
                source.text.components(separatedBy: "\n")
                    .filter { $0.contains(needle) && !isComment($0) }
                    .map { "\(source.name): \($0.trimmingCharacters(in: .whitespaces))" }
            }
            XCTAssertEqual(hits, [], "«\(needle)» на путях машины не встречается")
        }

        // Вектор непустоты поиска: заведомо присутствующая строка находится.
        let withNow = sources.filter { $0.text.contains("now: Date") }
        XCTAssertFalse(withNow.isEmpty, "разборщик видит то, что есть: `now: Date` в области есть")
    }

    // MARK: - К19 (текстовая половина) и К27 (инв. 6, вторая половина)

    /// Ни своего декодера, ни пути к ресурсу, ни числовых литералов пяти настроек и двух
    /// значений таблицы; ни собственного определения актуальности и ни второго выражения
    /// формулы слияния.
    func test_k19_k27_theMachineReadsValuesAndDefinesNoneOfThem() throws {
        let sources = try machineFiles()
        for needle in ["JSONDecoder(", "Bundle", "URL(fileURLWithPath:"] {
            let hits = sources.filter { $0.text.contains(needle) }.map(\.name)
            XCTAssertEqual(hits, [], "«\(needle)» на путях машины не встречается")
        }

        // Числа пяти настроек и двух значений таблицы — ни одного литералом. Область здесь
        // ровно файлы реализации: объявления `SessionCoordinator.swift` — чужая работа
        // (MEE-289), и пять полей `AppSettings` в ней не применяются ни разу.
        let written = sources.filter { $0.name.hasPrefix("SessionMachine") }
        for literal in ["120", "30", "900", "300", "0.2", "0,2", "60"] {
            let hits = written.flatMap { source in
                source.text.components(separatedBy: "\n")
                    .filter { line in
                        guard !isComment(line) else { return false }
                        return line.contains(literal)
                    }
                    .map { "\(source.name): \($0.trimmingCharacters(in: .whitespaces))" }
            }
            XCTAssertEqual(hits, [], "литерала «\(literal)» на путях машины нет")
        }

        // Формула слияния — одно место; актуальность — одно, и оба зовут значения таблицы.
        let formula = sources.flatMap { source in
            source.text.components(separatedBy: "\n").filter { $0.contains("reduce(1.0)") && !isComment($0) }
        }
        XCTAssertEqual(formula.count, 1, "второго выражения формулы слияния нет")
        let actuality = sources.flatMap { source in
            source.text.components(separatedBy: "\n")
                .filter { $0.contains("weights.signalTtlSeconds") && !isComment($0) }
        }
        // МЕСТ ДВА, А НЕ ОДНО, И ЭТО ПРАВКА ЧАСТИ B. Пункт требует, чтобы срок приходил
        // ЗНАЧЕНИЕМ ТАБЛИЦЫ, а не своим числом (литерал «60» запрещён проверкой выше);
        // «в одном месте» было верно ровно до §8.4, у которого отсчёт начинается в момент,
        // когда цель ВЫПАЛА ИЗ СЛИЯНИЯ, — то есть `observedAt` плюс тот же срок. Оба места
        // зовут один и тот же публичный член, и своего числа нет ни у одного.
        XCTAssertEqual(actuality.count, 2, "срок берётся у таблицы ВЕЗДЕ, где он нужен")
    }

    // MARK: - К28 (текстовая половина; инв. 7)

    /// Ноль сравнений `estimate` с числом и ноль вхождений `estimate` в условиях, ведущих к
    /// смене состояния. Это и есть различающая половина запрещающего пункта: поведенческая в
    /// части A зелена по построению, потому что в `recording` она не входит ни одним ходом.
    func test_k28_estimateStandsInNoConditionAtAll() throws {
        let sources = try machineFiles()
        let lines = sources.flatMap { source in
            source.text.components(separatedBy: "\n")
                .filter { $0.contains("estimate") && !isComment($0) }
                .map { (source.name, $0.trimmingCharacters(in: .whitespaces)) }
        }
        XCTAssertFalse(lines.isEmpty, "вектор непустоты: `estimate` в области есть — он вычисляется")

        for (name, line) in lines {
            // Стрелка возврата — не сравнение: в прогоне 146 этот пункт красил `-> Double`
            // у самой функции оценки. Признак исправлен снятием стрелки, и различающая сила
            // сохранена целиком — `if estimate > 0.5` ловится по-прежнему.
            let scanned = line.replacingOccurrences(of: "->", with: " ")
            for operatorText in [">", "<", ">=", "<=", "== 0.", "if "] {
                XCTAssertFalse(
                    scanned.contains("estimate") && scanned.contains(operatorText),
                    "`estimate` сравнивается либо стоит в условии: \(name): \(line)"
                )
            }
        }
    }

    // MARK: - К54 (§8.2, последний абзац)

    /// Машина не читает снимка прав: ноль вхождений четырёх имён. Область СПЛОШНАЯ —
    /// так читается колонка пункта плана, и отделимости путей она не требует.
    func test_k54_theMachineKnowsNothingAboutPermissions() throws {
        let sources = try files(in: "Sources/DomainCore")
            .filter { $0.name.hasPrefix("SessionMachine") || $0.name == "SessionCoordinator.swift" }
        for needle in ["PermissionSnapshot", "PermissionsPort", "permissionsReady", ".notifications"] {
            let hits = sources.filter { $0.text.contains(needle) }.map(\.name)
            XCTAssertEqual(hits, [], "«\(needle)» машина не читает")
        }
    }

    // MARK: - К83 (инв. 23)

    /// Ни один тип не импортирует системных фреймворков. Настоящий способ пункта — `Л`,
    /// сборка работой `Core (Linux)`: она зелена тогда и только тогда, когда это верно, и
    /// текстовая проверка ниже её не заменяет, а называет нарушителя поимённо.
    func test_k83_noSystemFrameworkImports() throws {
        let frameworks = [
            "AppKit", "UIKit", "CoreAudio", "EventKit", "IOKit",
            "AVFoundation", "UserNotifications", "ScreenCaptureKit", "CoreGraphics"
        ]
        let sources = try machineFiles()
        let imports = sources.flatMap { source in
            source.text.components(separatedBy: "\n")
                .filter { $0.hasPrefix("import ") }
                .map { $0.replacingOccurrences(of: "import ", with: "") }
        }
        XCTAssertFalse(imports.isEmpty, "вектор непустоты: строки `import` в области есть")
        XCTAssertEqual(Set(imports), ["Foundation"], "на путях машины импортируется только Foundation")
        for framework in frameworks {
            XCTAssertFalse(imports.contains(framework), "«\(framework)» не импортируется")
        }
    }

    // MARK: - Оснастка

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
