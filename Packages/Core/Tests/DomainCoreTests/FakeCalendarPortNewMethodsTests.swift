//  MEE-355/MEE-357: управляющая поверхность источника (beginAuth/completeAuth/
//  settingsSchema/configure/healthCheck/stop) на `DomainTestKit.FakeCalendarPort`.
//
//  Файл отделён от `FakeCalendarPortTests` по одному доводу и он механический: линт
//  считает тело типа длиннее двухсот пятидесяти строк нарушением. Предмет не делится —
//  делится текст, тем же приёмом, что `SessionMachinePowerTests`/`SessionMachineStopTests`.
//  Отдельный класс, а не `extension` того же типа: `eventKit`/`graph` в исходном файле
//  объявлены `private` — тот же уровень видимости в другом файле не видит их.

import XCTest
import DomainCore
import DomainTestKit

final class FakeCalendarPortNewMethodsTests: XCTestCase {

    private let eventKit = CalendarSourceId(rawValue: "eventkit")
    private let graph = CalendarSourceId(rawValue: "graph:work")

    // MARK: - (д) канонические значения на источник — beginAuth/healthCheck/settingsSchema

    func test_mee355_fakeCalendarPort_beginAuthReturnsCanonicalChallengePerSource() async throws {
        let port = FakeCalendarPort()
        let eventKitChallenge = AuthChallenge(
            authUrl: URL(string: "https://example.com/auth/ek")!, redirectScheme: "meetforme"
        )
        let graphChallenge = AuthChallenge(
            authUrl: URL(string: "https://example.com/auth/graph")!, redirectScheme: "meetforme"
        )
        port.setAuthChallenge(eventKitChallenge, for: eventKit)
        port.setAuthChallenge(graphChallenge, for: graph)

        let answerEventKit = try await port.beginAuth(source: eventKit)
        let answerGraph = try await port.beginAuth(source: graph)

        XCTAssertEqual(answerEventKit, eventKitChallenge)
        XCTAssertEqual(answerGraph, graphChallenge)
        XCTAssertNotEqual(answerEventKit, answerGraph, "вектор непустоты: источники различимы, не один ответ")
    }

    func test_mee355_fakeCalendarPort_healthCheckReturnsCanonicalHealthPerSource() async throws {
        let port = FakeCalendarPort()
        let healthy = ConnectorHealth(status: .ok, message: nil, lastSuccessfulSyncAt: nil)
        let degraded = ConnectorHealth(status: .degraded, message: "slow", lastSuccessfulSyncAt: nil)
        port.setConnectorHealth(healthy, for: eventKit)
        port.setConnectorHealth(degraded, for: graph)

        let answerEventKit = try await port.healthCheck(source: eventKit)
        let answerGraph = try await port.healthCheck(source: graph)

        XCTAssertEqual(answerEventKit, healthy)
        XCTAssertEqual(answerGraph, degraded)
    }

    func test_mee355_fakeCalendarPort_settingsSchemaReturnsCanonicalDataPerSource() async throws {
        let port = FakeCalendarPort()
        let eventKitSchema = Data("eventkit-schema".utf8)
        let graphSchema = Data("graph-schema".utf8)
        port.setSettingsSchema(eventKitSchema, for: eventKit)
        port.setSettingsSchema(graphSchema, for: graph)

        let answerEventKit = try await port.settingsSchema(source: eventKit)
        let answerGraph = try await port.settingsSchema(source: graph)

        XCTAssertEqual(answerEventKit, eventKitSchema)
        XCTAssertEqual(answerGraph, graphSchema)
    }

    // MARK: - (е) `completeAuth` — контракт не даёт канонического значения, только отказ

    func test_mee355_fakeCalendarPort_completeAuthReturnsNilWithoutCanonicalValue() async throws {
        let port = FakeCalendarPort()
        let label = try await port.completeAuth(source: eventKit, callbackUrl: URL(string: "meetforme://callback")!)
        XCTAssertNil(label, "контракт не даёт тесту канонического значения на этот ответ — только отказ")
    }

    // MARK: - (ж) `configure` — настройки, переданные тестом, наблюдаемы

    func test_mee355_fakeCalendarPort_configuredSettingsAreObservable() async throws {
        let port = FakeCalendarPort()
        XCTAssertNil(port.configuredSettings(for: eventKit), "до вызова настроек нет")
        let settings = Data(#"{"pollSeconds": 60}"#.utf8)
        try await port.configure(source: eventKit, settings: settings)
        XCTAssertEqual(port.configuredSettings(for: eventKit), settings)
        XCTAssertNil(port.configuredSettings(for: graph), "чужой источник не тронут")
    }

    // MARK: - (з) любой из пяти бросающих методов отказывает на ВЫБРАННОМ источнике

    func test_mee355_fakeCalendarPort_beginAuthFailsOnlyOnChosenSource() async throws {
        let port = FakeCalendarPort()
        let challenge = AuthChallenge(authUrl: URL(string: "https://example.com/auth")!, redirectScheme: "meetforme")
        port.setAuthChallenge(challenge, for: eventKit)
        port.setAuthChallenge(challenge, for: graph)
        port.fail(with: .authorizationRequired(sourceId: graph), on: .beginAuth, source: graph)

        let answer = try await port.beginAuth(source: eventKit)
        XCTAssertEqual(answer, challenge, "источник без отказа отвечает как обычно")
        do {
            _ = try await port.beginAuth(source: graph)
            XCTFail("ожидался отказ на выбранном источнике")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .authorizationRequired(sourceId: graph))
        }
    }

    func test_mee355_fakeCalendarPort_completeAuthFailsOnlyOnChosenSource() async throws {
        let port = FakeCalendarPort()
        port.fail(with: .protocolViolation(sourceId: graph, message: "bad state"), on: .completeAuth, source: graph)
        let url = URL(string: "meetforme://callback")!

        let answer = try await port.completeAuth(source: eventKit, callbackUrl: url)
        XCTAssertNil(answer)
        do {
            _ = try await port.completeAuth(source: graph, callbackUrl: url)
            XCTFail("ожидался отказ на выбранном источнике")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .protocolViolation(sourceId: graph, message: "bad state"))
        }
    }

    func test_mee355_fakeCalendarPort_settingsSchemaFailsOnlyOnChosenSource() async throws {
        let port = FakeCalendarPort()
        let schema = Data("schema".utf8)
        port.setSettingsSchema(schema, for: eventKit)
        port.setSettingsSchema(schema, for: graph)
        port.fail(with: .timeout(sourceId: graph, seconds: 5), on: .settingsSchema, source: graph)

        let answer = try await port.settingsSchema(source: eventKit)
        XCTAssertEqual(answer, schema)
        do {
            _ = try await port.settingsSchema(source: graph)
            XCTFail("ожидался отказ на выбранном источнике")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .timeout(sourceId: graph, seconds: 5))
        }
    }

    func test_mee355_fakeCalendarPort_configureFailsOnlyOnChosenSource() async throws {
        let port = FakeCalendarPort()
        port.fail(with: .transport(sourceId: graph, message: "boom"), on: .configure, source: graph)
        let settings = Data("settings".utf8)

        try await port.configure(source: eventKit, settings: settings)
        XCTAssertEqual(port.configuredSettings(for: eventKit), settings)
        do {
            try await port.configure(source: graph, settings: settings)
            XCTFail("ожидался отказ на выбранном источнике")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .transport(sourceId: graph, message: "boom"))
        }
        XCTAssertNil(port.configuredSettings(for: graph), "отказ — настройки не осели")
    }

    func test_mee355_fakeCalendarPort_healthCheckFailsOnlyOnChosenSource() async throws {
        let port = FakeCalendarPort()
        let health = ConnectorHealth(status: .ok, message: nil, lastSuccessfulSyncAt: nil)
        port.setConnectorHealth(health, for: eventKit)
        port.setConnectorHealth(health, for: graph)
        port.fail(with: .cancelled, on: .healthCheck, source: graph)

        let answer = try await port.healthCheck(source: eventKit)
        XCTAssertEqual(answer, health)
        do {
            _ = try await port.healthCheck(source: graph)
            XCTFail("ожидался отказ на выбранном источнике")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    // MARK: - (и) отказ на source: nil — на всяком источнике

    func test_mee355_fakeCalendarPort_failWithNilSourceFailsEverySource() async throws {
        let port = FakeCalendarPort()
        port.fail(with: .cancelled, on: .healthCheck)   // source: nil по умолчанию

        for source in [eventKit, graph] {
            do {
                _ = try await port.healthCheck(source: source)
                XCTFail("ожидался отказ на \(source.rawValue)")
            } catch let error as CalendarError {
                XCTAssertEqual(error, .cancelled)
            }
        }
    }

    // MARK: - (к) `stop()` — только счётчик, без возможности задать ему ошибку

    func test_mee355_fakeCalendarPort_stopCountsCallsWithoutThrowing() async {
        let port = FakeCalendarPort()
        XCTAssertEqual(port.stopCallCount, 0)
        await port.stop()
        await port.stop()
        XCTAssertEqual(port.stopCallCount, 2)
    }

    // MARK: - (л) журнал вызовов пишет все шесть новых методов

    /// Возврат РП по MEE-357: журнал (условие `Н`) обязан видеть все шесть методов
    /// управляющей поверхности источника, а не только семь прежних. Сами настройки
    /// `configure` в журнал не идут (SwiftLint `optional_data_string_conversion` — и
    /// довод самого журнала, «для равенства доменного значения — типизованный список,
    /// не текст», см. шапку `PortCallLog.swift`): их наблюдает `configuredSettings(for:)`.
    func test_mee357_fakeCalendarPort_journalRecordsAllSixNewMethods() async throws {
        let port = FakeCalendarPort()
        let challenge = AuthChallenge(authUrl: URL(string: "https://example.com/auth")!, redirectScheme: "meetforme")
        let health = ConnectorHealth(status: .ok, message: nil, lastSuccessfulSyncAt: nil)
        port.setAuthChallenge(challenge, for: eventKit)
        port.setConnectorHealth(health, for: eventKit)
        port.setSettingsSchema(Data("schema".utf8), for: eventKit)

        _ = try await port.beginAuth(source: eventKit)
        _ = try await port.completeAuth(source: eventKit, callbackUrl: URL(string: "meetforme://callback")!)
        _ = try await port.settingsSchema(source: eventKit)
        try await port.configure(source: eventKit, settings: Data(#"{"pollSeconds":60}"#.utf8))
        _ = try await port.healthCheck(source: eventKit)
        await port.stop()

        XCTAssertEqual(port.callLog.signatures, [
            "CalendarPort.beginAuth(source:)",
            "CalendarPort.completeAuth(source:callbackUrl:)",
            "CalendarPort.settingsSchema(source:)",
            "CalendarPort.configure(source:settings:)",
            "CalendarPort.healthCheck(source:)",
            "CalendarPort.stop()"
        ])
        XCTAssertEqual(port.configuredSettings(for: eventKit), Data(#"{"pollSeconds":60}"#.utf8))
    }
}
