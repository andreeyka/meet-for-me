//  SettingsTests — MEE-425, план MEE-410 группа Ж (К21-К24, §2/§2.1, инв. 18/28) + перечень
//  MEE-401 дельта АА (К53-К55): `AppFacadeImpl.settings()`/`updateSettings(_:)` на прямом
//  фейке репозитория настроек (`InMemorySettingsRepository`, ФНС), не `FakeAppFacade` (план
//  MEE-410, §0). К53-К55 — прямые проверки `AppSettings.slice1Defaults` и его исходного
//  текста, отдельно от К21 (который сверяет `settings()` с этой же константой, но не говорит,
//  чему сама константа равна — К21 и К53 дополняют друг друга, не дублируют).
//
//  Модуль: domain-core · Владелец: DEV-1 (в помощь MEE-420) · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class SettingsTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
    }

    private func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            settings: repositories.settings,
            clock: { Date() }
        )
        return Fixture(facade: facade, repositories: repositories)
    }

    /// Настройки, отличные от `AppSettings.slice1Defaults` во всех двенадцати полях —
    /// К23/К24 обеих нужно отличимое от умолчаний значение, чтобы «записалось»/«не
    /// записалось» вообще было наблюдаемо.
    private static func distinctSettings() -> AppSettings {
        AppSettings(
            recordingPolicy: .manual, armLeadSeconds: 121, askLeadSeconds: 31,
            missingSignalGraceSeconds: 901, silenceStopSeconds: 301, defaultProfileId: "profile-x",
            processOnACPowerOnly: true, processWhileRecording: true, audioRetentionDays: 14,
            voiceProfilesEnabled: true, notifyParticipants: true, launchAtLogin: true
        )
    }

    // MARK: - К21 (§2.1, «строки нет — берётся значение из slice1Defaults»)

    func test_k21_settingsReturnSliceDefaultsWhenNoRowsExist() async throws {
        let fixture = makeFixture()

        let settings = try await fixture.facade.settings()

        XCTAssertEqual(settings, AppSettings.slice1Defaults)
    }

    // MARK: - К22 (инв. 28, «строка есть, а байты не читаются — отказ, а не умолчание»)

    /// Порченые байты — на `defaultProfileId` (шестой ключ по порядку чтения `settings()`),
    /// не на первом: доказывает, что отказ действительно прерывает чтение НА этом ключе, а
    /// не просто оказывается единственным ключом, который вообще проверялся. Журнал вызовов
    /// (`ПКЛ`) показывает: пятый предшествующий ключ прочитан, шестой (порченый) — тоже
    /// прочитан (и на нём отказ), седьмой и далее — уже нет, чтение остановилось немедленно.
    func test_k22_undecodableBytesThrowSettingsUnreadableNoSilentFallback() async throws {
        let fixture = makeFixture()
        fixture.repositories.settings.seed(["defaultProfileId": Data("это не JSON вовсе".utf8)])

        do {
            _ = try await fixture.facade.settings()
            XCTFail("ожидался settingsUnreadable(key: \"defaultProfileId\")")
        } catch AppFacadeError.settingsUnreadable(let key) {
            XCTAssertEqual(key, "defaultProfileId")
        }

        let readKeys = fixture.repositories.log
            .calls(port: "SettingsRepository")
            .filter { $0.method == "value(forKey:)" }
            .map(\.arguments.first)
        XCTAssertEqual(
            readKeys,
            [
                "recordingPolicy", "armLeadSeconds", "askLeadSeconds", "missingSignalGraceSeconds",
                "silenceStopSeconds", "defaultProfileId"
            ],
            "чтение остановилось на порченом ключе — остальные шесть не запрошены"
        )
    }

    // MARK: - К23 (§2.1, «ключ — имя поля, значение — DomainJSON.encode»; round-trip)

    func test_k23_updateSettingsRoundTripsKeyAndDomainJSON() async throws {
        let fixture = makeFixture()
        let settings = Self.distinctSettings()

        try await fixture.facade.updateSettings(settings)

        let raw = try await fixture.repositories.settings.value(forKey: "recordingPolicy")
        let decoded = try DomainJSON.decode(AppSettings.RecordingPolicy.self, from: XCTUnwrap(raw))
        XCTAssertEqual(decoded, .manual, "ключ строки — дословно имя поля \"recordingPolicy\", lowerCamelCase")

        let roundTripped = try await fixture.facade.settings()
        XCTAssertEqual(roundTripped, settings, "запись, прочитанная обратно, даёт равное значение")
    }

    // MARK: - К24 (инв. 18, «применяет целиком и атомарно»)

    /// Отказ на третьем по порядку ключе (`askLeadSeconds` — `recordingPolicy`,
    /// `armLeadSeconds` идут раньше него в `AppSettings.init`, тот же порядок, что
    /// `settingsEntries(for:)`) — тот же пример, что называет сам перечень MEE-401.
    func test_k24_updateSettingsAtomicOnPartialWriteFailure() async throws {
        let fixture = makeFixture()
        fixture.repositories.settings.fail(with: .io(message: "диск недоступен"), on: .setValue, id: "askLeadSeconds")

        do {
            try await fixture.facade.updateSettings(Self.distinctSettings())
            XCTFail("ожидался отказ записи")
        } catch {
            // Ожидаемо — конкретный код здесь не предмет критерия, предмет ниже.
        }

        XCTAssertEqual(
            fixture.repositories.settings.storedKeys, [],
            "два уже записанных ключа (recordingPolicy, armLeadSeconds) откачены — ни один не остался"
        )
        let afterFailure = try await fixture.facade.settings()
        XCTAssertEqual(
            afterFailure, AppSettings.slice1Defaults,
            "состояние равно тому, что было до вызова — частично применённых настроек не бывает"
        )
    }

    // MARK: - К53 перечня MEE-401 (дельта АА): семь значений, названных контрактом буквально

    func test_k53_sliceDefaultsSevenContractNamedLiterals() {
        let defaults = AppSettings.slice1Defaults

        XCTAssertEqual(defaults.armLeadSeconds, 120)
        XCTAssertEqual(defaults.askLeadSeconds, 30)
        XCTAssertEqual(defaults.missingSignalGraceSeconds, 900)
        XCTAssertEqual(defaults.silenceStopSeconds, 300)
        XCTAssertNil(defaults.audioRetentionDays)
        XCTAssertEqual(defaults.notifyParticipants, false)
        XCTAssertEqual(defaults.voiceProfilesEnabled, false)
    }

    // MARK: - К54/К55 перечня MEE-401 (дельта АА, мех.): доковый комментарий на месте присвоения

    /// К54: `defaultProfileId` — значение присвоено (компиляцией: `AppSettings.init` не
    /// принимает отсутствующий аргумент) и комментарий на месте называет зависимость от
    /// каталога моделей C-014 — контракт требует именно эту зависимость названной, не любой
    /// текст вообще.
    func test_k54_defaultProfileIdAssignmentNamesC014DependencyInPlace() throws {
        let block = try Self.sliceDefaultsSourceBlock()
        let line = try XCTUnwrap(
            Self.line(containing: "defaultProfileId:", in: block), "presence of defaultProfileId: — компиляцией"
        )
        let comment = Self.precedingComment(before: line, in: block)
        XCTAssertTrue(comment.contains("C-014"), "комментарий на месте defaultProfileId называет C-014: \(comment)")
    }

    /// К55: `recordingPolicy`, `processOnACPowerOnly`, `processWhileRecording`, `launchAtLogin`
    /// — каждому присвоено значение (компиляцией) и сопровождено НЕПУСТЫМ комментарием на
    /// месте, называющим сам факт выбора — контракт не требует названного довода для этих
    /// четырёх (в отличие от `defaultProfileId`/`voiceProfilesEnabled`, где сам контракт
    /// называет причину).
    func test_k55_fourUnnamedFieldsHaveNonEmptyChoiceCommentInPlace() throws {
        let block = try Self.sliceDefaultsSourceBlock()
        for field in ["recordingPolicy:", "processOnACPowerOnly:", "processWhileRecording:", "launchAtLogin:"] {
            let line = try XCTUnwrap(Self.line(containing: field, in: block), "presence of \(field) — компиляцией")
            let comment = Self.precedingComment(before: line, in: block)
            XCTAssertFalse(comment.isEmpty, "\(field) — доковый комментарий на месте присвоения пуст")
        }
    }

    // MARK: - Оснастка К54/К55: разбор исходного текста AppSettings.swift

    /// Текст `AppSettings.swift` от строки `public static let slice1Defaults` до конца файла
    /// (константа — последнее объявление в файле) — блок, в котором ищутся присвоения полей.
    private static func sliceDefaultsSourceBlock() throws -> [String] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url = url.appendingPathComponent("Sources").appendingPathComponent("DomainCore")
            .appendingPathComponent("AppSettings.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let startIndex = try XCTUnwrap(lines.firstIndex { $0.contains("static let slice1Defaults") })
        return Array(lines[startIndex...])
    }

    private static func line(containing marker: String, in block: [String]) -> Int? {
        block.firstIndex { $0.contains(marker) }
    }

    /// Комментарий «на месте» — либо на самой строке присвоения (после `//`), либо на
    /// непосредственно предшествующей строке (стиль `slice1Defaults` в этом файле — комментарий
    /// строкой выше поля, которое он поясняет). Пусто, если нет ни того, ни другого.
    private static func precedingComment(before lineIndex: Int, in block: [String]) -> String {
        if let range = block[lineIndex].range(of: "//") {
            let inline = String(block[lineIndex][range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !inline.isEmpty { return inline }
        }
        guard lineIndex > 0 else { return "" }
        let previous = block[lineIndex - 1].trimmingCharacters(in: .whitespaces)
        guard previous.hasPrefix("//") else { return "" }
        return String(previous.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
}
