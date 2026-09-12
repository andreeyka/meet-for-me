//  П. 146: три эталонные таблицы правил читаются `DomainJSON.decode(_:from:)` в DTO,
//  объявленные в `domain-core`.
//
//  Свойства эталонов (а)…(е) п. 146 проверяются QA по тексту литерала методом М3: тест на
//  успешном декодировании зелен и на эталоне, полученном из нашего же кодировщика, то есть
//  проверял бы не то. Здесь — равенство прочитанного значению, собранному в коде, свойство (в)
//  и два вектора отказа (ж) и (з).
//
//  Свойство (в) проверяется на DTO, а не на значениях `SignalWeights`, и это решающее место:
//  `SignalWeights` отказывается собираться из таблицы, набор ключей которой не равен набору
//  видов сигнала, — сравнение на нём было бы зелёным по построению. DTO хранит ключи такими,
//  какими они стояли в файле, и сравнение на нём опровержимо.

import XCTest
import DomainCore

final class RulesTablesTests: XCTestCase {

    func test_p146_rulesTables_providers_referenceEqualsValueBuiltInCode() throws {
        let read = try DomainJSON.decode(ProvidersTable.self,
                                         from: Data(ReferenceTables.providers.utf8))
        let expected = ProvidersTable(schemaVersion: 1, providers: [
            ProvidersTable.Provider(
                provider: "zoom", displayName: "Zoom", priority: 10,
                urlPatterns: [ProvidersTable.URLPattern(
                    hostSuffix: "zoom.us",
                    pathRegex: "^/(j|s|w)/(?<meetingId>[0-9]+)",
                    meetingIdQueryKey: nil, passcodeQueryKey: "pwd")]),
            ProvidersTable.Provider(
                provider: "meet", displayName: "Google Meet", priority: 20,
                urlPatterns: [ProvidersTable.URLPattern(
                    hostSuffix: "meet.google.com",
                    pathRegex: "^/(?<meetingId>[a-z]{3}-[a-z]{4}-[a-z]{3})",
                    meetingIdQueryKey: nil, passcodeQueryKey: nil)]),
        ])
        XCTAssertEqual(read, expected)
        XCTAssertEqual(read.providers.map(\.priority), [10, 20], "порядок записей сохранён")
    }

    func test_p146_rulesTables_clients_referenceEqualsValueBuiltInCode() throws {
        let read = try DomainJSON.decode(ClientsTable.self,
                                         from: Data(ReferenceTables.clients.utf8))
        let expected = ClientsTable(
            schemaVersion: 1,
            browsers: ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
                       "com.microsoft.edgemac", "com.brave.Browser",
                       "ru.yandex.desktop.yandex-browser"],
            clients: [
                ClientsTable.Client(provider: "zoom", bundleIds: ["us.zoom.xos"],
                                    browserFallback: true),
                ClientsTable.Client(provider: "teams", bundleIds: ["com.microsoft.teams2"],
                                    browserFallback: true),
                ClientsTable.Client(provider: "meet", bundleIds: [], browserFallback: true),
            ])
        XCTAssertEqual(read, expected)
        XCTAssertEqual(read.clients[2].bundleIds, [], "пустой список — «нативного клиента нет»")
    }

    func test_p146_rulesTables_signalWeights_referenceEqualsValueBuiltInCode() throws {
        let read = try DomainJSON.decode(SignalWeightsTable.self,
                                         from: Data(ReferenceTables.signalWeights.utf8))
        let expected = SignalWeightsTable(
            schemaVersion: 1,
            signalTtlSeconds: 60,
            weights: ["calendarWindow": 0.2, "clientRunning": 0.4,
                      "microphoneInUse": 0.4, "clientAudioOutput": 0.8])
        XCTAssertEqual(read, expected)
    }

    /// Свойство (в): обе стороны сравнения взяты из текстов — ключи из прочитанного эталона,
    /// виды сигнала из кода через `allCases`. Ни одна не выписана литералом в самом сравнении.
    func test_p146_rulesTables_weightKeys_matchSignalKindRawValues() throws {
        let read = try DomainJSON.decode(SignalWeightsTable.self,
                                         from: Data(ReferenceTables.signalWeights.utf8))
        let fromFile = Set(read.weights.keys)
        let fromCode = Set(MeetingSignalKind.allCases.map(\.rawValue))
        XCTAssertEqual(fromFile, fromCode)
        XCTAssertEqual(fromFile.count, 4)
        XCTAssertEqual(fromCode.count, 4)
    }

    /// Вектор (ж) Q36: неизвестная версия схемы у любой из трёх — отказ с именем ключа.
    func test_p146_rulesTables_unknownSchemaVersion_isRejected() {
        let providers = ReferenceTables.withSchemaVersion(2, in: ReferenceTables.providers)
        let clients = ReferenceTables.withSchemaVersion(2, in: ReferenceTables.clients)
        let weights = ReferenceTables.withSchemaVersion(2, in: ReferenceTables.signalWeights)
        assertCorrupted(try DomainJSON.decode(ProvidersTable.self, from: Data(providers.utf8)),
                        key: "schemaVersion")
        assertCorrupted(try DomainJSON.decode(ClientsTable.self, from: Data(clients.utf8)),
                        key: "schemaVersion")
        assertCorrupted(try DomainJSON.decode(SignalWeightsTable.self, from: Data(weights.utf8)),
                        key: "schemaVersion")
    }

    /// Вектор (з) Q36: отсутствующая версия схемы у любой из трёх — отказ с именем ключа.
    func test_p146_rulesTables_missingSchemaVersion_isRejected() {
        let providers = ReferenceTables.withoutSchemaVersion(ReferenceTables.providers)
        let clients = ReferenceTables.withoutSchemaVersion(ReferenceTables.clients)
        let weights = ReferenceTables.withoutSchemaVersion(ReferenceTables.signalWeights)
        XCTAssertFalse(providers.contains("schemaVersion"), "ключ действительно снят")
        assertKeyNotFound(try DomainJSON.decode(ProvidersTable.self, from: Data(providers.utf8)),
                          key: "schemaVersion")
        assertKeyNotFound(try DomainJSON.decode(ClientsTable.self, from: Data(clients.utf8)),
                          key: "schemaVersion")
        assertKeyNotFound(try DomainJSON.decode(SignalWeightsTable.self, from: Data(weights.utf8)),
                          key: "schemaVersion")
    }
}
