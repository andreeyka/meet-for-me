//  П. 153 перечня MEE-6: полнота объявления протокола `PlatformResolver` против §2 C-009.
//  Способ — пункт плана 153 (MEE-7, дельта `Щ`, раздел `Щ.4`): текстовая проверка по
//  исходникам, исполняемая как тест. Тест лежит в общем таргете и потому идёт в обеих
//  работах CI; платформенной различающей силы у текстовой проверки нет.
//
//  Область названа планом дословно: от строки `public protocol PlatformResolver: Sendable {`
//  до закрывающей скобки блока, МИНУС строки, начинающиеся с `//`. Исключение комментариев
//  несущее, а не косметическое: до этой задачи единственным вхождением `resolve(event`
//  во всём `Packages/Core` был комментарий, объяснявший, почему метода нет, и проверка
//  подстрокой по файлу зеленела ровно на том дереве, ради которого написана. Вектор Q41
//  проверяет само исключение — на образце, а не на сегодняшнем файле.
//
//  Состав и порядок — два разных утверждения, и они проверяются порознь: перестановка двух
//  требований множества не меняет. Метка `event` проверяется отдельно от имени: два требования
//  `resolve` различаются только ею, и проверка по одному имени `resolve` зелена при любом
//  из двух.
//
//  Чего пункт не проверяет: ни одной реализации метода и ни одного его поведения — это
//  инварианты 3—5 C-009, перечень MEE-75, сторона `detector`.
//
//  ВТОРЫМ РАЗДЕЛОМ — векторы п. 149 на разбор события фейком, и место у них здесь по зоне,
//  а не по родству. `FixedPlatformResolver` получил `resolve(event:)` этой же задачей, и
//  поведение без своей проверки нарушало бы П8. Положить её было некуда: чужой тест
//  (`DomainTestKitFakesTests.swift`) правке не подлежит, а четвёртый файл в `Packages/Core`
//  выходит за зону MEE-220 (§6 постановки — три названных файла). Названо в отчёте.

import Foundation
import XCTest
import DomainCore
import DomainTestKit

final class ProtocolDeclarationTests: XCTestCase {

    /// Блок §2 C-009 дословно, в порядке контракта.
    static let contractRequirements = [
        "func resolve(event: MeetingEvent) -> JoinInfo?",
        "func resolve(text: String, source: JoinInfo.Source) -> JoinInfo?",
        "func clientBundleIds(for provider: String) -> [String]",
        "func allKnownClientBundleIds() -> [String]",
        "func provider(forAppKey appKey: String) -> String?",
        "func isBrowser(appKey: String) -> Bool"
    ]

    static let blockHeader = "public protocol PlatformResolver: Sendable {"

    // MARK: - Состав

    /// Шесть требований, ни одним больше: поверхность, которой контракт не обещал, — то же
    /// нарушение П2, что и недостача.
    func test_p153_platformResolverDeclaration_declaresExactlyTheSixOfContract() throws {
        let declared = try declaredRequirements()
        XCTAssertEqual(declared.count, 6, "требований в блоке: \(declared)")
        XCTAssertEqual(Set(declared), Set(Self.contractRequirements),
                       "множество сигнатур разошлось с §2 C-009")
    }

    // MARK: - Порядок

    /// Порядок значим (§2 и правило обхода C-001 §0.2 п. 9): сравнивается последовательность.
    func test_p153_platformResolverDeclaration_keepsContractOrder() throws {
        XCTAssertEqual(try declaredRequirements(), Self.contractRequirements)
    }

    // MARK: - Метка первого аргумента

    /// `resolve(event:)` и `resolve(text:source:)` различаются только меткой; обе обязаны быть.
    func test_p153_platformResolverDeclaration_distinguishesResolveByArgumentLabel() throws {
        let declared = try declaredRequirements()
        XCTAssertEqual(declared.filter { $0.contains("func resolve(event: MeetingEvent)") }.count, 1)
        XCTAssertEqual(declared.filter { $0.contains("func resolve(text: String,") }.count, 1)
    }

    // MARK: - Q41: исключение комментариев из области

    /// Закомментированное требование требованием не считается. Образец, а не сегодняшний файл:
    /// на файле это утверждение проверить нечем — комментария такого вида в нём больше нет.
    func test_p153_platformResolverDeclaration_commentedRequirementIsNotCounted() {
        let sample = """
        \(Self.blockHeader)
            // func resolve(event: MeetingEvent) -> JoinInfo?
            func isBrowser(appKey: String) -> Bool
        }
        """
        XCTAssertEqual(Self.requirements(in: sample), ["func isBrowser(appKey: String) -> Bool"])
    }

    /// И обратная половина того же вектора: за закрывающей скобкой блока область кончается.
    func test_p153_platformResolverDeclaration_stopsAtClosingBrace() {
        let sample = """
        \(Self.blockHeader)
            func isBrowser(appKey: String) -> Bool
        }

        func resolve(event: MeetingEvent) -> JoinInfo? { nil }
        """
        XCTAssertEqual(Self.requirements(in: sample), ["func isBrowser(appKey: String) -> Bool"])
    }

    // MARK: - П. 149. Разбор события фейком: словарь теста и порядок полей

    /// Фейк спрашивает о каждом поле свой же словарь и идёт в порядке инварианта 3:
    /// `conference` (по `joinUrl.absoluteString`) → `location` → `bodyText`.
    func test_p149_fixedPlatformResolver_resolvesEventByDictionaryInFieldOrder() throws {
        let zoom = try answer(provider: "zoom", url: "https://zoom.us/j/1", source: .conferenceField)
        let meet = try answer(provider: "meet", url: "https://meet.google.com/abc", source: .location)
        let telemost = try answer(provider: "telemost", url: "https://telemost.yandex.ru/j/7", source: .bodyText)
        let resolver = FixedPlatformResolver(answers: ["https://zoom.us/j/1": zoom,
                                                       "комната мита": meet,
                                                       "хвост письма": telemost])
        let conference = try MeetingEvent.Conference(provider: "zoom", joinUrl: zoom.joinUrl,
                                                     meetingId: nil, passcode: nil)
        XCTAssertEqual(resolver.resolve(event: try event(conference: conference,
                                                         location: "комната мита",
                                                         bodyText: "хвост письма")), zoom)
        XCTAssertEqual(resolver.resolve(event: try event(location: "комната мита",
                                                         bodyText: "хвост письма")), meet)
        XCTAssertEqual(resolver.resolve(event: try event(bodyText: "хвост письма")), telemost)
    }

    /// Вектор п. 149 «текста нет в словаре → `nil`» остаётся верным и на событии: исключения
    /// инварианта 4 (`provider == "unknown"`) у фейка нет, и это решение — см. его заголовок.
    func test_p149_fixedPlatformResolver_answersNilWhenNoFieldIsInTheDictionary() throws {
        let zoom = try answer(provider: "zoom", url: "https://zoom.us/j/1", source: .conferenceField)
        let resolver = FixedPlatformResolver(answers: ["https://zoom.us/j/1": zoom])
        let conference = try MeetingEvent.Conference(provider: "unknown",
                                                     joinUrl: try XCTUnwrap(URL(string: "https://vc.example.org/9")),
                                                     meetingId: nil, passcode: nil)
        XCTAssertNil(resolver.resolve(event: try event(conference: conference,
                                                       location: "чего в словаре нет",
                                                       bodyText: "и этого тоже")))
        XCTAssertNil(resolver.resolve(event: try event()))
    }

    // MARK: - Оснастка

    private func answer(provider: String, url: String, source: JoinInfo.Source) throws -> JoinInfo {
        JoinInfo(provider: provider,
                 joinUrl: try XCTUnwrap(URL(string: url)),
                 meetingId: nil,
                 passcode: nil,
                 clientBundleIds: [],
                 source: source)
    }

    private func event(conference: MeetingEvent.Conference? = nil,
                       location: String? = nil,
                       bodyText: String? = nil) throws -> MeetingEvent {
        try MeetingEvent(
            id: try XCTUnwrap(UUID(uuidString: "5A1E0149-0000-4000-8000-000000000001")),
            sourceConnectorId: "eventkit",
            externalId: "evt-149",
            icalUid: nil,
            title: "Разбор события фейком",
            start: Date(timeIntervalSince1970: 1_789_119_000),
            end: Date(timeIntervalSince1970: 1_789_120_800),
            timeZone: "Europe/Moscow",
            isAllDay: false,
            isCancelled: false,
            organizer: nil,
            attendees: [],
            location: location,
            bodyText: bodyText,
            conference: conference,
            lastModified: Date(timeIntervalSince1970: 1_789_041_600)
        )
    }

    private func declaredRequirements() throws -> [String] {
        let text = try platformResolverSource()
        XCTAssertFalse(text.isEmpty, "исходник протокола не прочитан — проверка была бы пустой")
        XCTAssertTrue(text.contains(Self.blockHeader), "блок протокола не найден по своей шапке")
        return Self.requirements(in: text)
    }

    private func platformResolverSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DomainCore/PlatformResolver.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Строки области: тело блока протокола без пустых строк и без строк-комментариев.
    static func requirements(in text: String) -> [String] {
        var inside = false
        var depth = 0
        var body: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if !inside {
                guard line.contains(blockHeader) else { continue }
                inside = true
                depth = braceBalance(of: line)
                continue
            }
            depth += braceBalance(of: line)
            if depth <= 0 {
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("//") {
                body.append(trimmed)
            }
        }
        return body
    }

    private static func braceBalance(of line: String) -> Int {
        line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
    }
}
