//  MEE-346, возврат РП: управляющая поверхность `DomainTestKit.FakeConnectorHostServices` —
//  счётчики `secretGet`/`secretSet`/`log`/`notify`, главное требование постановки к фейку.
//
//  Образец — `FakeCalendarPortTests` (MEE-290): счёт и журнал по каждому методу протокола,
//  а не общий факт «фейк вызывался». `secretSet(key:value: nil)` проверяется отдельно —
//  постановка требует, чтобы это было удаление ключа, а не хранение явного `nil`.

import XCTest
import DomainCore
import DomainTestKit

final class FakeConnectorHostServicesTests: XCTestCase {

    // MARK: - secretGet / secretSet

    func test_mee346_fakeConnectorHostServices_secretGetReturnsWhatSecretSetStored() async throws {
        let fake = FakeConnectorHostServices()
        XCTAssertNil(try await fake.secretGet(key: "token"), "ключ, которого не задавали, не значение")
        XCTAssertEqual(fake.callCount("secretGet(key:)"), 1)

        try await fake.secretSet(key: "token", value: "abc")
        XCTAssertEqual(fake.callCount("secretSet(key:value:)"), 1)
        XCTAssertEqual(try await fake.secretGet(key: "token"), "abc")
        XCTAssertEqual(fake.callCount("secretGet(key:)"), 2, "счёт растёт по вызову, а не по ключу")
    }

    /// `setSecret(_:for:)` — управление из теста, а не вызов порта: счётчик `secretGet` им
    /// не движется, движется только самим `secretGet(key:)`.
    func test_mee346_fakeConnectorHostServices_setSecretPresetsWithoutCountingAsACall() async throws {
        let fake = FakeConnectorHostServices()
        fake.setSecret("preset", for: "token")
        XCTAssertEqual(fake.callCount("secretGet(key:)"), 0, "задание секрета тестом не вызов порта")

        XCTAssertEqual(try await fake.secretGet(key: "token"), "preset")
        XCTAssertEqual(fake.callCount("secretGet(key:)"), 1)
        XCTAssertEqual(fake.secret(for: "token"), "preset", "то же значение читается и способом теста")
    }

    /// `secretSet(key:value: nil)` УДАЛЯЕТ ключ — тот же ответ, что и у ключа, которого не
    /// задавали ни разу (не хранит явный `nil` отдельной записью).
    func test_mee346_fakeConnectorHostServices_secretSetWithNilRemovesTheKey() async throws {
        let fake = FakeConnectorHostServices()
        fake.setSecret("abc", for: "token")
        XCTAssertEqual(fake.secret(for: "token"), "abc")

        try await fake.secretSet(key: "token", value: nil)
        XCTAssertNil(fake.secret(for: "token"), "ключ удалён — не хранит явный nil")
        XCTAssertNil(try await fake.secretGet(key: "token"), "secretGet отвечает так же, как у незаданного ключа")
    }

    // MARK: - log

    func test_mee346_fakeConnectorHostServices_logRecordsEveryEntryInOrder() {
        let fake = FakeConnectorHostServices()
        fake.log(.warning, "первое")
        fake.log(.error, "второе")

        XCTAssertEqual(fake.loggedMessages.map { $0.level.rawValue }, ["warning", "error"])
        XCTAssertEqual(fake.loggedMessages.map { $0.message }, ["первое", "второе"])
        XCTAssertEqual(fake.callCount("log(_:_:)"), 2)
    }

    // MARK: - notify

    func test_mee346_fakeConnectorHostServices_notifyRecordsEveryEntryIncludingNilDetail() {
        let fake = FakeConnectorHostServices()
        fake.notify(.authExpired, detail: "истёк токен")
        fake.notify(.changesAvailable, detail: nil)

        XCTAssertEqual(fake.notifications.map { $0.kind.rawValue }, ["authExpired", "changesAvailable"])
        XCTAssertEqual(fake.notifications.map { $0.detail }, ["истёк токен", nil])
        XCTAssertEqual(fake.callCount("notify(_:detail:)"), 2)
    }

    // MARK: - Общий журнал (условие `Н`)

    /// Журнал, переданный в инициализатор, — тот же объект, что вернёт `callLog`, и вызовы
    /// разных методов ложатся в него в одном порядке, поперёк методов, а не по одному на метод.
    func test_mee346_fakeConnectorHostServices_sharedLogKeepsCrossMethodOrder() async throws {
        let log = PortCallLog()
        let fake = FakeConnectorHostServices(log: log)
        XCTAssertTrue(fake.callLog === log, "журнал — тот же объект, что дали в инициализатор")

        fake.log(.info, "старт")
        _ = try await fake.secretGet(key: "k")
        fake.notify(.configInvalid, detail: nil)

        XCTAssertEqual(log.signatures, [
            "ConnectorHostServices.log(_:_:)",
            "ConnectorHostServices.secretGet(key:)",
            "ConnectorHostServices.notify(_:detail:)"
        ])
    }
}
