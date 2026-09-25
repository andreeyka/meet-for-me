//  EngineXPCClientErrorMappingTests+Cocoa — план MEE-389: К50 (единственные два пути к
//  `invalidRequest`, не третий через `NSCocoaErrorDomain`), К51 (четыре вектора
//  `NSCocoaErrorDomain` настоящего `NSXPCConnection`). Разведено из
//  `EngineXPCClientErrorMappingTests.swift` по объёму (`type_body_length`), не по смыслу —
//  тот же класс, `makeSpec`/`readyFixture` там же, не `private` ради этого файла.

import Foundation
import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

extension EngineXPCClientErrorMappingTests {

    // MARK: - К50: единственные два пути к invalidRequest — не третий через NSCocoaErrorDomain

    /// К50: `invalidRequest` образуется только кодом транспорта `3` (К32) и нераспознанным
    /// кодом `4` (К33) — третьего пути нет. Здесь — прямое доказательство: ЛЮБОЙ код домена
    /// `NSCocoaErrorDomain` (даже не входящий в четыре вектора К51) уходит в `mapCocoaConnectionError`,
    /// который `invalidRequest` не возвращает никогда, только `serviceCrashed`/`serviceUnavailable`.
    func test_k50_arbitraryCocoaDomainCodeNeverMapsToInvalidRequest() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (
            data: nil, error: NSError(domain: NSCocoaErrorDomain, code: 999_999)
        )

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable, не invalidRequest")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо — К51(iv): любой не названный явно код домена уходит сюда, не в invalidRequest
        }
    }

    // MARK: - К51: четыре вектора NSCocoaErrorDomain настоящего NSXPCConnection

    /// К51(i): `NSXPCConnectionInterrupted` (реальный код, каким его несёт настоящий
    /// `NSXPCConnection.remoteObjectProxyWithErrorHandler`) → `serviceCrashed`, тем же путём,
    /// что интерпретирует `connectionDied(crashed: true)` на уровне соединения (К29), но
    /// здесь — на уровне ОДНОГО отказавшего вызова (`map(nsError:)`), не всего соединения.
    func test_k51_cocoaConnectionInterruptedMapsToServiceCrashed() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (
            data: nil, error: NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)
        )

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceCrashed")
        } catch TranscriptionServiceError.serviceCrashed {
            // ожидаемо
        }
    }

    /// К51(ii): `NSXPCConnectionInvalid` → `serviceUnavailable`.
    /// Возврат РП по MEE-431 (10:27 UTC): не только случай ошибки — сообщение тоже (домен,
    /// код, описание, тем же форматом `describe(_:)`, что К51(iv)).
    func test_k51_cocoaConnectionInvalidMapsToServiceUnavailable() async throws {
        let fixture = try await readyFixture()
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid,
            userInfo: [NSLocalizedDescriptionKey: "соединение недействительно"]
        )
        fixture.service.forcedRawResponse = (data: nil, error: error)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable(let message) {
            XCTAssertEqual(message, "\(NSCocoaErrorDomain) \(NSXPCConnectionInvalid): соединение недействительно")
        }
    }

    /// К51(iii): `NSXPCConnectionReplyInvalid` → тот же `serviceUnavailable`.
    func test_k51_cocoaConnectionReplyInvalidMapsToServiceUnavailable() async throws {
        let fixture = try await readyFixture()
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid,
            userInfo: [NSLocalizedDescriptionKey: "ответ не разобран XPC"]
        )
        fixture.service.forcedRawResponse = (data: nil, error: error)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable(let message) {
            XCTAssertEqual(message, "\(NSCocoaErrorDomain) \(NSXPCConnectionReplyInvalid): ответ не разобран XPC")
        }
    }

    /// К51(iv): любой другой код `NSCocoaErrorDomain` → `serviceUnavailable(message: "<домен>
    /// <код>: <описание>")`, тем же форматом, что общий постор-случай (`describe(_:)`); этот
    /// же вектор закрывает бывший К50(iii) — третьего пути к `invalidRequest` из этого домена нет.
    func test_k51_otherCocoaDomainCodeMapsToServiceUnavailableWithDomainCodeDescription() async throws {
        let fixture = try await readyFixture()
        // Код заведомо вне кластера NSXPCConnection* (4097/4099/4101) — этот вектор
        // проверяет фолбэк на «постороннее», не один из трёх названных кодов.
        let arbitraryCode = 5_000_000
        let error = NSError(
            domain: NSCocoaErrorDomain, code: arbitraryCode, userInfo: [NSLocalizedDescriptionKey: "нечто постороннее"]
        )
        fixture.service.forcedRawResponse = (data: nil, error: error)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable(let message) {
            XCTAssertEqual(message, "\(NSCocoaErrorDomain) \(arbitraryCode): нечто постороннее")
        }
    }
}
