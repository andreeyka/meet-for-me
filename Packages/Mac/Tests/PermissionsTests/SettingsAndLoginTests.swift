//  Критерии перечня MEE-74 на `openSettings(for:)` и автозапуск: 40, 41, 43, 44 и механическая
//  половина 9 (на подставленной регистрации). Настоящий раздел настроек и настоящий login item —
//  ручные прогоны М2 и М3.

import DomainCore
import Foundation
import XCTest
@testable import Permissions

final class SettingsAndLoginTests: XCTestCase {

    // MARK: - 40. Отказ открытия → settingsPaneUnavailable(kind:) с тем же kind

    func test_c40_openSettingsFailure_throwsSettingsPaneUnavailable_withSameKind() async {
        for kind in PermissionKind.allCases {
            let harness = PermissionsHarness()
            harness.settings.fail([kind])
            do {
                try await harness.sut.openSettings(for: kind)
                XCTFail("\(kind): ожидался отказ")
            } catch let error as PermissionsError {
                XCTAssertEqual(error, .settingsPaneUnavailable(kind: kind))
            } catch {
                XCTFail("\(kind): чужая ошибка \(error)")
            }
            XCTAssertEqual(harness.settings.opened, [kind])
        }
    }

    func test_c40_openSettingsSuccess_doesNotThrow() async throws {
        let harness = PermissionsHarness()
        for kind in PermissionKind.allCases {
            try await harness.sut.openSettings(for: kind)
        }
        XCTAssertEqual(harness.settings.opened, PermissionKind.allCases)
    }

    // MARK: - 41. Отказ openSettings не выводит порт из строя

    func test_c41_portWorksAfterSettingsFailure() async {
        let harness = PermissionsHarness([.accessibility: .denied])
        harness.settings.fail(Set(PermissionKind.allCases))
        do {
            try await harness.sut.openSettings(for: .microphone)
            XCTFail("ожидался отказ")
        } catch {
            XCTAssertTrue(error is PermissionsError)
        }
        let snapshot = await harness.sut.snapshot()
        XCTAssertEqual(snapshot.states.count, 6)
        let status = await harness.sut.status(of: .accessibility)
        XCTAssertEqual(status, .denied)
        let outcome = await harness.sut.request(.accessibility)
        XCTAssertEqual(outcome, .cannotPrompt)
    }

    // MARK: - 43, 44. Отказ регистрации login item не фатален; message — текст

    func test_c43_c44_loginItemFailure_isReportedAndPortKeepsWorking() async throws {
        let harness = PermissionsHarness([.accessibility: .denied])
        harness.loginItems.fail(with: "регистрация отклонена системой")
        do {
            try await harness.sut.setLaunchAtLogin(true)
            XCTFail("ожидался отказ")
        } catch let error as PermissionsError {
            guard case .loginItemRegistrationFailed(let message) = error else {
                return XCTFail("другая ошибка: \(error)")
            }
            XCTAssertFalse(message.isEmpty)
            let bytes = try JSONEncoder().encode(error)
            let decoded = try JSONDecoder().decode(PermissionsError.self, from: bytes)
            XCTAssertEqual(decoded, error, "переживает кодирование")
        } catch {
            XCTFail("чужая ошибка \(error)")
        }
        let enabled = await harness.sut.isLaunchAtLoginEnabled()
        XCTAssertFalse(enabled)
        let snapshot = await harness.sut.snapshot()
        XCTAssertEqual(snapshot.states.count, 6)
        let status = await harness.sut.status(of: .accessibility)
        XCTAssertEqual(status, .denied)
        let outcome = await harness.sut.request(.accessibility)
        XCTAssertEqual(outcome, .cannotPrompt)
    }

    func test_c43_loginItemFailure_withEmptySystemText_stillHasMessage() async {
        let harness = PermissionsHarness()
        harness.loginItems.fail(with: "")
        do {
            try await harness.sut.setLaunchAtLogin(true)
            XCTFail("ожидался отказ")
        } catch let error as PermissionsError {
            guard case .loginItemRegistrationFailed(let message) = error else {
                return XCTFail("другая ошибка: \(error)")
            }
            XCTAssertFalse(message.isEmpty, "пустой текст системы заменён описанием ошибки")
        } catch {
            XCTFail("чужая ошибка \(error)")
        }
    }

    // MARK: - 9, механическая половина. true → true, false → false на подставленной регистрации

    func test_c09_mechanicalHalf_setLaunchAtLogin_roundTrip() async throws {
        let harness = PermissionsHarness()
        try await harness.sut.setLaunchAtLogin(true)
        let enabled = await harness.sut.isLaunchAtLoginEnabled()
        XCTAssertTrue(enabled)
        try await harness.sut.setLaunchAtLogin(false)
        let disabled = await harness.sut.isLaunchAtLoginEnabled()
        XCTAssertFalse(disabled)
    }

    // MARK: - Якоря разделов настроек — по одному на право, из перечня SecurityPrivacyExtension

    func test_settingsPaneURLs_areDefinedForEveryKind() throws {
        for kind in PermissionKind.allCases {
            let url = try XCTUnwrap(SettingsPane.url(for: kind), "\(kind)")
            XCTAssertEqual(url.scheme, "x-apple.systempreferences", "\(kind)")
        }
        XCTAssertEqual(SettingsPane.url(for: .systemAudioRecording)?.query, "Privacy_AudioCapture")
    }
}
