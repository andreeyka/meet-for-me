//  Пп. 150 и 151: форма публичного почленного инициализатора четырёх структур раздела
//  «Определение» C-009 и то, что значение собирается и хранится дословно.
//
//  Q34: сборка идёт ИЗ ДРУГОГО МОДУЛЯ и без `@testable`. Синтезированный почленный
//  инициализатор `public struct` с `public let`-полями остаётся `internal`, за границу модуля
//  не выходит и внутри своего модуля выглядит так же, как публичный; проверка, сделанная с
//  `@testable import`, зелена на нарушителе. Здесь импорт обычный — и одно это отличает
//  публичный инициализатор от синтезированного.
//
//  Форму — порядок параметров, метки, равные именам полей, отсутствие значений по умолчанию
//  и отсутствие `throws` — доказывает сам факт компиляции этих вызовов: метки написаны в
//  порядке объявления полей, ни один аргумент не опущен, ни один вызов не обёрнут в `try`.
//
//  Границу п. 150 повторяю, потому что она решает, чего здесь НЕТ: DTO трёх таблиц правил под
//  признак «структура раздела „Определение“» не подпадают — раздел их не объявляет, а способ
//  их построения есть декодирование (§6). Проверки почленного `init` у них здесь нет ни одной.
//
//  П. 151 — пять парных векторов: инициализатор не бросает И ни одно поле им не изменено.
//  Второе важнее первого: «ничего не проверяет» отличается от «тихо нормализует» только им.
//  Запрет ОТДАВАТЬ такие значения проверяют К34, К51, К49, К47 и К20 перечня MEE-75 — на той
//  стороне, которая отдала; здесь проверяется только сборка.

import XCTest
import DomainCore

final class C009ConstructionTests: XCTestCase {

    // MARK: - 150. Форма публичного почленного инициализатора

    func test_p150_memberwiseInitShape_audioProcess() {
        let value = AudioProcess(pid: 900,
                                 bundleId: "com.google.Chrome.helper",
                                 responsibleBundleId: "com.google.Chrome",
                                 executableName: "Google Chrome Helper",
                                 isRunningOutput: true,
                                 isRunningInput: false,
                                 observedAt: moment)
        XCTAssertEqual(value.pid, 900)
        XCTAssertEqual(value.executableName, "Google Chrome Helper")
    }

    func test_p150_memberwiseInitShape_processGroup() {
        let value = ProcessGroup(appKey: "com.google.Chrome", pids: [120, 900], observedAt: moment)
        XCTAssertEqual(value.appKey, "com.google.Chrome")
        XCTAssertEqual(value.observedAt, moment)
    }

    func test_p150_memberwiseInitShape_meetingSignal() {
        let value = MeetingSignal(kind: .microphoneInUse,
                                  weight: 0.4,
                                  pid: 900,
                                  bundleId: "com.google.Chrome.helper",
                                  group: nil,
                                  provider: nil,
                                  meetingId: nil,
                                  observedAt: moment)
        XCTAssertEqual(value.kind, .microphoneInUse)
        XCTAssertNil(value.group)
    }

    func test_p150_memberwiseInitShape_joinInfo() throws {
        let value = JoinInfo(provider: "zoom",
                             joinUrl: try makeURL("https://zoom.us/j/123"),
                             meetingId: "123",
                             passcode: "pwd",
                             clientBundleIds: ["us.zoom.xos"],
                             source: .eventUrl)
        XCTAssertEqual(value.provider, "zoom")
        XCTAssertEqual(value.source, .eventUrl)
    }

    // MARK: - 151. Значение собирается и хранится дословно

    /// Инв. 15, пара к К34: производить такую запись запрещено, собрать — нет.
    func test_p151_constructionVerbatim_emptyBundleIdIsKept() {
        let value = AudioProcess(pid: 1, bundleId: "", responsibleBundleId: nil,
                                 executableName: "x", isRunningOutput: false,
                                 isRunningInput: false, observedAt: moment)
        XCTAssertEqual(value.bundleId, "")
        XCTAssertEqual(value, value)
    }

    /// Инв. 18, пара к К51: порядок сохранён, сортировки не происходит.
    func test_p151_constructionVerbatim_unsortedPidsAreKept() {
        let value = ProcessGroup(appKey: "com.google.Chrome", pids: [900, 120], observedAt: moment)
        XCTAssertEqual(value.pids, [900, 120])
    }

    /// Инв. 17 и «`appKey` — непустая строка» §1, пара к К49.
    func test_p151_constructionVerbatim_emptyAppKeyIsKept() {
        let value = ProcessGroup(appKey: "", pids: [1], observedAt: moment)
        XCTAssertEqual(value.appKey, "")
    }

    /// Инв. 11, пара к К47: зажатия в `0...1` нет.
    func test_p151_constructionVerbatim_weightOutOfRangeIsKept() {
        let value = MeetingSignal(kind: .clientAudioOutput, weight: 1.5, pid: 900,
                                  bundleId: nil, group: nil, provider: nil, meetingId: nil,
                                  observedAt: moment)
        XCTAssertEqual(value.weight, 1.5)
    }

    /// Инв. 6, пара к К20: провайдер вне множества ключей хранится как передан.
    func test_p151_constructionVerbatim_unknownProviderIsKept() throws {
        let value = JoinInfo(provider: "нет-такого",
                             joinUrl: try makeURL("https://example.com/x"),
                             meetingId: nil, passcode: nil, clientBundleIds: [],
                             source: .location)
        XCTAssertEqual(value.provider, "нет-такого")
    }

    private var moment: Date { date(milliseconds: 1_757_000_000_000) }
}
