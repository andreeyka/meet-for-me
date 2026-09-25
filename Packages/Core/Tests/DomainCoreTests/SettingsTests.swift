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
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
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

    /// Ещё одно отличимое значение, отличное и от `slice1Defaults`, И от `distinctSettings()`
    /// — К24 (возврат РП, `4d1d45a5`) нужно ВТОРОЕ значение для отказавшего вызова поверх уже
    /// непустого, не умолчательного хранилища, чтобы откат на удаление ключа отличался от
    /// отката на восстановление прежнего значения (на пустом хранилище оба совпадают).
    private static func otherDistinctSettings() -> AppSettings {
        AppSettings(
            recordingPolicy: .auto, armLeadSeconds: 200, askLeadSeconds: 40,
            missingSignalGraceSeconds: 950, silenceStopSeconds: 350, defaultProfileId: "profile-y",
            processOnACPowerOnly: false, processWhileRecording: false, audioRetentionDays: 30,
            voiceProfilesEnabled: false, notifyParticipants: false, launchAtLogin: false
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

    // MARK: - Возврат РП (MEE-425, комментарий `4d1d45a5`): инв. 19 у settingsField

    /// `settingsField` раньше ловил только `StorageError` — прочая ошибка хранилища уходила
    /// из `settings()` наружу СВОИМ типом, нарушая инв. 19 («ошибка нижнего слоя не пропускает
    /// наружу свой тип, признак — не перечень имён»). `FailingSettingsRepository` бросает
    /// заведомо постороннюю ошибку (не `StorageError`) — `settings()` обязана завернуть её в
    /// `AppFacadeError.underlying`, тем же путём, что `updateSettings(_:)` уже делает своим
    /// внешним `catch`.
    func test_settingsWrapsNonStorageErrorFromRepositoryAsAppFacadeError() async throws {
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
            settings: FailingSettingsRepository(),
            clock: { Date() }
        )

        do {
            _ = try await facade.settings()
            XCTFail("ожидался AppFacadeError")
        } catch let error as AppFacadeError {
            guard case .underlying(let view) = error else {
                return XCTFail("ожидался .underlying, получено \(error)")
            }
            XCTAssertTrue(
                view.message.contains(FailingSettingsRepository.failureMessage),
                "сообщение постороннней ошибки сохранено: \(view.message)"
            )
        } catch {
            XCTFail("ожидался AppFacadeError, получено \(error)")
        }
    }

    // MARK: - К23 (§2.1, «ключ — имя поля, значение — DomainJSON.encode»; round-trip)

    /// Возврат РП (MEE-425, комментарий `4d1d45a5`): имя ключа раньше сверялось только у
    /// `recordingPolicy` — двенадцать ключей выписаны строками ДВАЖДЫ (`settings()` и
    /// `settingsEntries(for:)`), и одинаковая опечатка в обоих местах (например,
    /// `"launchOnLogin"` вместо `"launchAtLogin"`) прошла бы этот тест молча. `Mirror(reflecting:
    /// settings).children` даёт метки полей НЕЗАВИСИМО от обоих мест — не третье переписывание
    /// того же перечня, а получение состава прямо из значения через рефлексию.
    func test_k23_updateSettingsRoundTripsKeyAndDomainJSON() async throws {
        let fixture = makeFixture()
        let settings = Self.distinctSettings()

        try await fixture.facade.updateSettings(settings)

        let raw = try await fixture.repositories.settings.value(forKey: "recordingPolicy")
        let decoded = try DomainJSON.decode(AppSettings.RecordingPolicy.self, from: XCTUnwrap(raw))
        XCTAssertEqual(decoded, .manual, "ключ строки — дословно имя поля \"recordingPolicy\", lowerCamelCase")

        let writtenKeys = Set(fixture.repositories.settings.storedKeys)
        let fieldLabels = Set(Mirror(reflecting: settings).children.compactMap(\.label))
        XCTAssertEqual(
            writtenKeys, fieldLabels,
            "множество записанных ключей равно меткам полей AppSettings — ловит опечатку ключа в любом месте"
        )

        let roundTripped = try await fixture.facade.settings()
        XCTAssertEqual(roundTripped, settings, "запись, прочитанная обратно, даёт равное значение")
    }

    // MARK: - К24 (инв. 18, «применяет целиком и атомарно»)

    /// Отказ на третьем по порядку ключе (`askLeadSeconds` — `recordingPolicy`,
    /// `armLeadSeconds` идут раньше него в `AppSettings.init`, тот же порядок, что
    /// `settingsEntries(for:)`) — тот же пример, что называет сам перечень MEE-401.
    ///
    /// Возврат РП (MEE-425, комментарий `4d1d45a5`): откат раньше проверялся только на
    /// ПУСТОМ хранилище — там «восстановить прежнее» и «удалить ключ» неотличимы (прежнего
    /// значения не было вовсе). Здесь хранилище ПРЕДВАРИТЕЛЬНО заполнено не умолчательными
    /// значениями (`original`, первый успешный `updateSettings`), и только ВТОРОЙ вызов
    /// (другим значением, `otherDistinctSettings()`) отказывает на середине — откат удалением
    /// ключа дал бы `settings()` смесь `original`/`slice1Defaults`, не `original` целиком.
    func test_k24_updateSettingsAtomicOnPartialWriteFailure() async throws {
        let fixture = makeFixture()
        let original = Self.distinctSettings()
        try await fixture.facade.updateSettings(original)

        fixture.repositories.settings.fail(with: .io(message: "диск недоступен"), on: .setValue, id: "askLeadSeconds")

        do {
            try await fixture.facade.updateSettings(Self.otherDistinctSettings())
            XCTFail("ожидался отказ записи")
        } catch {
            // Ожидаемо — конкретный код здесь не предмет критерия, предмет ниже.
        }

        XCTAssertEqual(
            fixture.repositories.settings.storedKeys.count, 12,
            "откат ВОССТАНОВИЛ прежние значения двух уже записанных ключей — ключей не убавилось"
        )
        let afterFailure = try await fixture.facade.settings()
        XCTAssertEqual(
            afterFailure, original,
            "состояние равно тому, что было ДО второго вызова (непустое, не умолчания) — не бывает частично применённых"
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

    /// Комментарий «на месте» — либо на самой строке присвоения (после `//`), либо ВЕСЬ
    /// непрерывный блок `//`-строк непосредственно перед ней (стиль `slice1Defaults` в этом
    /// файле — многострочный комментарий над полем, которое он поясняет), не только
    /// последняя строка блока. Возврат РП (MEE-425, комментарий `4d1d45a5`): одна строка —
    /// хрупко при переносе строк в комментарии; собирает от присвоения вверх, пока строки
    /// начинаются с `//`, и склеивает в исходном порядке. Пусто, если нет ни того, ни другого.
    private static func precedingComment(before lineIndex: Int, in block: [String]) -> String {
        if let range = block[lineIndex].range(of: "//") {
            let inline = String(block[lineIndex][range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !inline.isEmpty { return inline }
        }
        var collected: [String] = []
        var index = lineIndex - 1
        while index >= 0 {
            let trimmed = block[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { break }
            collected.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            index -= 1
        }
        return collected.reversed().joined(separator: " ")
    }
}

/// `SettingsRepository`, чей `value(forKey:)` бросает заведомо ПОСТОРОННЮЮ ошибку (не
/// `StorageError`) — единственный способ проверить, что `settingsField` заворачивает её в
/// `AppFacadeError`, а не пропускает своим типом (инв. 19). `InMemorySettingsRepository.fail(
/// with:on:)` для этого не годится: она типизирована на `StorageError` буквально в сигнатуре.
private struct FailingSettingsRepository: SettingsRepository {
    struct Opaque: Error {
        let message: String
    }

    static let failureMessage = "постороннее хранилище отказало (не StorageError)"

    func value(forKey key: String) async throws -> Data? {
        throw Opaque(message: Self.failureMessage)
    }

    func setValue(_ value: Data?, forKey key: String) async throws {}
}
