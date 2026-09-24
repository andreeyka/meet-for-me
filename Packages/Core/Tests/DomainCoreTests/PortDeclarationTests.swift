//  MEE-289 (девять протоколов) + MEE-319 (ещё семь: пять портов C-010 §5,
//  `JobRepository` и `ModelCatalogPort` C-013) + MEE-346 (ещё два: `ConnectorHostServices`
//  и `CalendarConnector`, C-006 §6): полнота и порядок объявлений против разделов
//  «Определение» их контрактов-владельцев, и имена полей `AppSettings` против §2.1 C-016.
//
//  ПОЧЕМУ ЭТИ ПРОВЕРКИ, А НЕ ДРУГИЕ. Предмет MEE-289 — объявления, поведения в нём нет
//  ни строки, и тестов на поведение постановка запрещает прямо. Что остаётся проверяемым,
//  названо её §4: сборка, символьный граф и инварианты типов там, где их требует контракт.
//  Ни один из восьми контрактов-владельцев (C-004, C-005, C-006, C-010, C-013, C-015, C-016,
//  C-018) не распространяет на свои типы `DomainValidatable` C-001 §0.2 — проверено прогоном
//  по каждому тексту целиком, вхождений ноль, — поэтому пути декодирования и почленного
//  инициализатора здесь проверять нечем: они синтезированы и зелены по построению.
//  Исключение — `MeetingEventPayload` (C-006 §6.1): `DomainValidatable` он несёт, но это
//  отдельный тип со своими тестами (`MeetingEventPayloadTests.swift`), а не один из двух
//  протоколов этого файла.
//
//  Остаётся ровно то, что сборка НЕ ловит, и оно здесь:
//    1) недостача или лишнее требование в протоколе — форма прецедента MEE-86 (п. 153
//       перечня MEE-6, тест `ProtocolDeclarationTests`). Реализации у этих портов сегодня
//       нет ни одной, поэтому недостающий метод не краснит ни одну сборку;
//    2) порядок требований — перестановка множества не меняет, а контракт порядок задаёт;
//    3) имена и порядок полей `AppSettings`. Это не украшение: §2.1 C-016 говорит, что ключ
//       строки `app_settings` ЕСТЬ имя поля дословно, и «одно названное место, где
//       отображение живёт, — объявление `AppSettings`». Переименование поля молча меняет
//       ключ хранилища, и не ловит этого сегодня ничто. Проверяется `Mirror` по живому
//       значению, а не текстом: так проверяется скомпилированный тип, а не исходник.
//
//  ГРАНИЦА НАЗВАНА. Проверка текстовая: она доказывает, ЧТО объявлено, и не доказывает
//  ни одного ответа ни одной реализации — их не существует. Требование, закомментированное
//  в исходнике, требованием не считается (вектор ниже); требование, записанное иначе, чем
//  в контракте, покраснеет, даже если оно верно по смыслу, — это цена дословности, и она
//  принята: расхождение читается на приёмке за один взгляд.
//
//  Ожидаемые блоки контрактов (восемнадцать статических массивов, структура `PortContract`
//  и сам список `contracts`) живут в `PortContractExpectations.swift`, тем же типом через
//  `extension` — деление по объёму, а не по смыслу: файл на весь класс целиком превышал и
//  порог `file_length`, и порог `type_body_length` SwiftLint (--strict, «Core + Mac»).

import Foundation
import XCTest
import DomainCore

final class PortDeclarationTests: XCTestCase {
}

extension PortDeclarationTests {

    // MARK: - Состав

    /// Ни одним требованием меньше и ни одним больше: поверхность, которой контракт
    /// не обещал, — то же нарушение П2, что и недостача.
    func test_mee289_everyPortDeclaresExactlyTheRequirementsOfItsContract() throws {
        for contract in Self.contracts {
            let declared = try Self.requirements(ofProtocol: contract.name, inFile: contract.file)
            XCTAssertEqual(Set(declared), Set(contract.expected),
                           "множество требований \(contract.name) разошлось с его контрактом")
        }
    }

    // MARK: - Порядок

    /// Порядок задан контрактом и здесь проверяется отдельно от состава: перестановка
    /// двух требований множества не меняет, и первая проверка её пропускает.
    func test_mee289_everyPortKeepsTheOrderOfItsContract() throws {
        for contract in Self.contracts {
            let declared = try Self.requirements(ofProtocol: contract.name, inFile: contract.file)
            XCTAssertEqual(declared, contract.expected,
                           "порядок требований \(contract.name) разошёлся с его контрактом")
        }
    }

    // MARK: - Исходник действительно прочитан

    /// Без этого обе проверки выше зелены на пустой строке: пустое множество равно пустому.
    func test_mee289_sourcesAreActuallyRead() throws {
        for contract in Self.contracts {
            let declared = try Self.requirements(ofProtocol: contract.name, inFile: contract.file)
            XCTAssertFalse(declared.isEmpty, "блок \(contract.name) прочитан пустым")
        }
    }

    // MARK: - Область разбора: комментарий требованием не является

    /// Закомментированное требование не считается. Образец, а не сегодняшний файл:
    /// проверяется само исключение, а не дерево, на котором оно сегодня ни на чём не сказывается.
    func test_mee289_commentedRequirementIsNotCounted() {
        let sample = """
        public protocol Scheduler: Sendable {
            // func plan(now: Date) async throws -> [ScheduledArm]
            func stop() async   // хвостовой комментарий тоже не часть требования
        }
        """
        XCTAssertEqual(Self.requirements(in: sample, protocolNamed: "Scheduler"), ["func stop() async"])
    }

    /// Обратная половина: за закрывающей скобкой блока область кончается.
    func test_mee289_parsingStopsAtClosingBrace() {
        let sample = """
        public protocol Scheduler: Sendable {
            func stop() async
        }

        public protocol Другой: Sendable {
            func plan(now: Date) async throws -> [ScheduledArm]
        }
        """
        XCTAssertEqual(Self.requirements(in: sample, protocolNamed: "Scheduler"), ["func stop() async"])
    }

    /// Требование, разнесённое по строкам, склеивается в одно: так объявлен `JobHandler.run`.
    func test_mee289_wrappedRequirementIsOneRequirement() {
        let sample = """
        public protocol JobHandler: Sendable {
            var type: JobType { get }
            func run(_ job: Job,
                     progress: @Sendable @escaping (Double) -> Void) async -> JobOutcome
        }
        """
        XCTAssertEqual(Self.requirements(in: sample, protocolNamed: "JobHandler"), Self.jobHandler)
    }

    // MARK: - §2.1 C-016: ключи `app_settings` суть имена полей `AppSettings`

    /// Имена и порядок полей проверяются по живому значению, а не по исходнику: §2.1
    /// объявляет отображение правилом, и его единственное место — это объявление.
    /// Переименование поля здесь молча сменило бы ключ строки `app_settings`.
    func test_mee289_appSettingsFieldNamesAreTheStorageKeys() throws {
        let expected = [
            "recordingPolicy",
            "armLeadSeconds",
            "askLeadSeconds",
            "missingSignalGraceSeconds",
            "silenceStopSeconds",
            "defaultProfileId",
            "processOnACPowerOnly",
            "processWhileRecording",
            "audioRetentionDays",
            "voiceProfilesEnabled",
            "notifyParticipants",
            "launchAtLogin"
        ]
        let settings = AppSettings(
            recordingPolicy: .ask,
            armLeadSeconds: 120,
            askLeadSeconds: 30,
            missingSignalGraceSeconds: 900,
            silenceStopSeconds: 300,
            defaultProfileId: "профиль-вектора",
            processOnACPowerOnly: true,
            processWhileRecording: false,
            audioRetentionDays: nil,
            voiceProfilesEnabled: true,
            notifyParticipants: false,
            launchAtLogin: true
        )
        // Замыкание, а не ключевой путь: `Mirror.Child` — кортеж, а ключевых путей
        // к элементам кортежа Swift 5.9 не имеет, и `\.label` здесь не собралось бы.
        let declared = Mirror(reflecting: settings).children.compactMap { $0.label }
        XCTAssertEqual(declared, expected, "имена или порядок полей AppSettings разошлись с §2 C-016")
    }

    // MARK: - Оснастка

    private static func requirements(ofProtocol name: String, inFile file: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DomainCore/\(file)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return requirements(in: text, protocolNamed: name)
    }

    /// Тело блока протокола: строки без комментариев и без пустых, склеенные по требованиям.
    /// Требование начинается со своего ключевого слова; всё прочее — продолжение предыдущего.
    static func requirements(in text: String, protocolNamed name: String) -> [String] {
        let header = "public protocol \(name): Sendable {"
        var inside = false
        var depth = 0
        var found: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            if !inside {
                guard rawLine.contains(header) else { continue }
                inside = true
                depth = braceBalance(of: rawLine)
                continue
            }
            depth += braceBalance(of: rawLine)
            if depth <= 0 { break }
            let line = withoutComment(rawLine)
            guard !line.isEmpty else { continue }
            if startsRequirement(line) {
                found.append(line)
            } else if !found.isEmpty {
                found[found.count - 1] += " " + line
            }
        }
        return found
    }

    /// Хвостовой комментарий отрезается вместе со строкой-комментарием: и тот и другой
    /// требованием не являются, а различать их здесь нечем и незачем.
    private static func withoutComment(_ line: String) -> String {
        let body = line.components(separatedBy: "//").first ?? ""
        return body.trimmingCharacters(in: .whitespaces)
    }

    private static func startsRequirement(_ line: String) -> Bool {
        ["func ", "var ", "static ", "init", "associatedtype ", "subscript"]
            .contains { line.hasPrefix($0) }
    }

    /// Баланс скобок строки. `{ get }` в требовании-свойстве сходится сам с собой и
    /// глубину блока не сдвигает — потому она и считается по строке, а не по символу.
    private static func braceBalance(of line: String) -> Int {
        line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
    }
}
