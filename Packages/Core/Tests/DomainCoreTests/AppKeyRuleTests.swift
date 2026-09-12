//  Пп. 144 и 145: правило §4.1 C-009 — шаг 1 (`AudioProcess.appKey`) и шаг 2
//  (`bundleKeyMatches(appKey:entry:)`). Код влит MEE-86, тестов на него не было ни одного.
//
//  Импорт без `@testable` здесь несущий, а не привычка: `@testable` открыл бы `internal`,
//  и проверка перестала бы отличать публичное объявление от синтезированного.
//
//  Второй вектор обоих пунктов — инвариант 16 (чистота): те же входы в перемешанном порядке
//  и из параллельных задач дают те же ответы. Он зелен по построению на сегодняшней
//  реализации — оба тела суть по одному выражению без обращения к состоянию, — и назван
//  здесь именно поэтому. Ловит он не «ничего»: кэш, мемоизацию, чтение `Bundle`, `Date`
//  или прав внутри функции и зависимость от порядка элементов снимка.

import XCTest
import DomainCore

final class AppKeyRuleTests: XCTestCase {

    // MARK: - 144. Шаг 1: appKey = responsibleBundleId ?? bundleId

    func test_p144_appKeyStep1_responsibleBundleIdWins() {
        let process = audioProcess(pid: 1, bundleId: "com.google.Chrome.helper",
                                   responsibleBundleId: "com.google.Chrome")
        XCTAssertEqual(process.appKey, "com.google.Chrome")
    }

    func test_p144_appKeyStep1_ownBundleIdWhenResponsibleMissing() {
        let chrome = audioProcess(pid: 2, bundleId: "com.google.Chrome.helper",
                                  responsibleBundleId: nil)
        let webKit = audioProcess(pid: 3, bundleId: "com.apple.WebKit.GPU",
                                  responsibleBundleId: nil)
        XCTAssertEqual(chrome.appKey, "com.google.Chrome.helper")
        XCTAssertEqual(webKit.appKey, "com.apple.WebKit.GPU")
    }

    func test_p144_appKeyStep1_bothMissingGivesNil() {
        let process = audioProcess(pid: 4, bundleId: nil, responsibleBundleId: nil)
        XCTAssertNil(process.appKey)
    }

    /// Q28: пустая строка остаётся пустой строкой и `nil` не становится. Приведение `""` → `nil`
    /// есть работа производящей стороны (К34), а не этого свойства.
    func test_p144_appKeyStep1_emptyBundleIdStaysEmpty() {
        let process = audioProcess(pid: 5, bundleId: "", responsibleBundleId: nil)
        XCTAssertEqual(process.appKey, "")
    }

    func test_p144_appKeyStep1_isPureUnderShuffleAndParallelTasks() async {
        let inputs = appKeyCases()
        let expected = Dictionary(uniqueKeysWithValues: inputs.map { ($0.process.pid, $0.appKey) })
        let answers = await withTaskGroup(of: [Int32: String?].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    Dictionary(uniqueKeysWithValues: inputs.shuffled()
                        .map { ($0.process.pid, $0.process.appKey) })
                }
            }
            var collected: [[Int32: String?]] = []
            for await answer in group { collected.append(answer) }
            return collected
        }
        XCTAssertEqual(answers.count, 8)
        for answer in answers {
            XCTAssertEqual(answer, expected)
        }
    }

    // MARK: - 145. Шаг 2: равенство либо потомок по точке

    func test_p145_bundleKeyMatches_equalityAndDottedPrefix() {
        XCTAssertTrue(bundleKeyMatches(appKey: "com.google.Chrome", entry: "com.google.Chrome"))
        XCTAssertTrue(bundleKeyMatches(appKey: "com.google.Chrome.helper",
                                       entry: "com.google.Chrome"))
    }

    /// Q30: единственный вектор, отличающий `hasPrefix(entry + ".")` от `hasPrefix(entry)`.
    func test_p145_bundleKeyMatches_withoutDotDoesNotMatch() {
        XCTAssertFalse(bundleKeyMatches(appKey: "com.google.ChromeX", entry: "com.google.Chrome"))
    }

    func test_p145_bundleKeyMatches_parentIsNotChild() {
        XCTAssertFalse(bundleKeyMatches(appKey: "com.google", entry: "com.google.Chrome"))
    }

    func test_p145_bundleKeyMatches_nilAppKeyNeverMatches() {
        XCTAssertFalse(bundleKeyMatches(appKey: nil, entry: "com.google.Chrome"))
    }

    /// Строка 4 таблицы §4.1: на Safari шаг 2 не спасает.
    func test_p145_bundleKeyMatches_safariHelperDoesNotMatch() {
        XCTAssertFalse(bundleKeyMatches(appKey: "com.apple.WebKit.GPU", entry: "com.apple.Safari"))
    }

    /// Q29: обе половины пустой строки стоят в одном тесте — порознь каждая зелена на
    /// реализации, потерявшей ветку. Ответ получен подстановкой в формулу §4.1, а не отдельным
    /// правилом: пустая строка в таблице — битая таблица, и ловит её К5 (i) у `detector`.
    func test_p145_bundleKeyMatches_emptyEntry() {
        XCTAssertFalse(bundleKeyMatches(appKey: "com.google.Chrome", entry: ""))
        XCTAssertTrue(bundleKeyMatches(appKey: "", entry: ""))
    }

    func test_p145_bundleKeyMatches_isPureUnderShuffleAndParallelTasks() async {
        let inputs = matchCases()
        let expected = Dictionary(uniqueKeysWithValues: inputs.enumerated().map { ($0.offset, $0.element.answer) })
        let answers = await withTaskGroup(of: [Int: Bool].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var answered: [Int: Bool] = [:]
                    for index in inputs.indices.shuffled() {
                        answered[index] = bundleKeyMatches(appKey: inputs[index].appKey,
                                                           entry: inputs[index].entry)
                    }
                    return answered
                }
            }
            var collected: [[Int: Bool]] = []
            for await answer in group { collected.append(answer) }
            return collected
        }
        XCTAssertEqual(answers.count, 8)
        for answer in answers {
            XCTAssertEqual(answer, expected)
        }
    }
}

// MARK: - Входы, общие для векторов чистоты

private func audioProcess(pid: Int32, bundleId: String?, responsibleBundleId: String?) -> AudioProcess {
    AudioProcess(pid: pid,
                 bundleId: bundleId,
                 responsibleBundleId: responsibleBundleId,
                 executableName: "probe",
                 isRunningOutput: false,
                 isRunningInput: false,
                 observedAt: date(milliseconds: 1_757_000_000_000))
}

/// Пять входов шага 1 — дословно по п. 144.
private func appKeyCases() -> [(process: AudioProcess, appKey: String?)] {
    [
        (audioProcess(pid: 1, bundleId: "com.google.Chrome.helper",
                      responsibleBundleId: "com.google.Chrome"), "com.google.Chrome"),
        (audioProcess(pid: 2, bundleId: "com.google.Chrome.helper",
                      responsibleBundleId: nil), "com.google.Chrome.helper"),
        (audioProcess(pid: 3, bundleId: "com.apple.WebKit.GPU",
                      responsibleBundleId: nil), "com.apple.WebKit.GPU"),
        (audioProcess(pid: 4, bundleId: nil, responsibleBundleId: nil), nil),
        (audioProcess(pid: 5, bundleId: "", responsibleBundleId: nil), ""),
    ]
}

/// Пара входа и ожидаемого ответа шага 2. Структурой, а не кортежем: трёхчленный кортеж
/// правило `large_tuple` линтера считает нарушением, а `--strict` делает его отказом.
private struct MatchCase {
    let appKey: String?
    let entry: String
    let answer: Bool
}

/// Семь пар шага 2 — дословно по п. 145; у (vii) обе половины.
private func matchCases() -> [MatchCase] {
    [
        MatchCase(appKey: "com.google.Chrome", entry: "com.google.Chrome", answer: true),
        MatchCase(appKey: "com.google.Chrome.helper", entry: "com.google.Chrome", answer: true),
        MatchCase(appKey: "com.google.ChromeX", entry: "com.google.Chrome", answer: false),
        MatchCase(appKey: "com.google", entry: "com.google.Chrome", answer: false),
        MatchCase(appKey: nil, entry: "com.google.Chrome", answer: false),
        MatchCase(appKey: "com.apple.WebKit.GPU", entry: "com.apple.Safari", answer: false),
        MatchCase(appKey: "com.google.Chrome", entry: "", answer: false),
        MatchCase(appKey: "", entry: "", answer: true),
    ]
}
