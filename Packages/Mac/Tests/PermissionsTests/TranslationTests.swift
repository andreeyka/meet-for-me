//  Критерии перечня MEE-74 на перевод исхода системного чтения (шов 1.б): 1.б, 17, 21.
//
//  Вход — то, что отдаёт системный вызов права, включая значения, которых перечисление системы
//  сегодня не знает, и исход «чтение не удалось». Перевод исполняет настоящий `StatusTranslation`
//  через настоящий `TranslatingStatusSource`.

import AVFoundation
import DomainCore
import EventKit
import Foundation
import UserNotifications
import XCTest
@testable import Permissions

final class TranslationTests: XCTestCase {

    /// Все исходы чтения каждого из пяти прав с публичным статусом, включая незнакомое системное
    /// значение и «чтение не удалось».
    static let readings: [PermissionKind: [SystemReading]] = [
        .microphone: [.notDetermined, .restricted, .denied, .authorized, AVAuthorizationStatus(rawValue: 99)]
            .compactMap { $0 }.map { .microphone($0) } + [.unreadable, .calendars(.denied)],
        .screenRecording: [.screenRecording(granted: true), .screenRecording(granted: false), .unreadable],
        .calendars: [.notDetermined, .restricted, .denied, .fullAccess, .writeOnly, EKAuthorizationStatus(rawValue: 99)]
            .compactMap { $0 }.map { .calendars($0) } + [.unreadable],
        .notifications: [.notDetermined, .denied, .authorized, .provisional, UNAuthorizationStatus(rawValue: 99)]
            .compactMap { $0 }.map { .notifications($0) } + [.unreadable],
        .accessibility: [.accessibility(trusted: true), .accessibility(trusted: false), .unreadable]
    ]

    // MARK: - 21. Ни одно право, кроме системного звука, не даёт .unknown ни при одном исходе

    func test_c21_noReadingOutcome_yieldsUnknown_forFiveKinds() async {
        var vectors = 0
        for (kind, readings) in Self.readings {
            for reading in readings {
                let (_, sut) = PermissionsHarness.reading([kind: reading])
                let status = await sut.status(of: kind)
                XCTAssertNotEqual(status, .unknown, "\(kind) при \(reading)")
                let snapshot = await sut.snapshot()
                XCTAssertNotEqual(snapshot.status(of: kind), .unknown, "\(kind) при \(reading) в снимке")
                vectors += 1
            }
        }
        XCTAssertEqual(vectors, 26, "векторов перебора: 7 + 3 + 7 + 6 + 3")
    }

    // MARK: - 17. «Универсальный доступ» не принимает .notDetermined ни при одном исходе

    func test_c17_accessibility_neverNotDetermined() async {
        for reading in Self.readings[.accessibility] ?? [] {
            let (_, sut) = PermissionsHarness.reading([.accessibility: reading])
            let status = await sut.status(of: .accessibility)
            XCTAssertNotEqual(status, .notDetermined, "\(reading)")
            let snapshot = await sut.snapshot()
            XCTAssertNotEqual(snapshot.status(of: .accessibility), .notDetermined, "\(reading) в снимке")
        }
        XCTAssertEqual(StatusTranslation.status(of: .accessibility, reading: .accessibility(trusted: true),
                                                promptedThisLaunch: false), .granted)
        XCTAssertEqual(StatusTranslation.status(of: .accessibility, reading: .accessibility(trusted: false),
                                                promptedThisLaunch: false), .denied)
    }

    // MARK: - 1.б. Таблица перевода — поимённо

    func test_c01b_translationTable() {
        let translate = { (kind: PermissionKind, reading: SystemReading) in
            StatusTranslation.status(of: kind, reading: reading, promptedThisLaunch: false)
        }
        XCTAssertEqual(translate(.microphone, .microphone(.notDetermined)), .notDetermined)
        XCTAssertEqual(translate(.microphone, .microphone(.restricted)), .restricted)
        XCTAssertEqual(translate(.microphone, .microphone(.denied)), .denied)
        XCTAssertEqual(translate(.microphone, .microphone(.authorized)), .granted)
        XCTAssertEqual(translate(.calendars, .calendars(.notDetermined)), .notDetermined)
        XCTAssertEqual(translate(.calendars, .calendars(.restricted)), .restricted)
        XCTAssertEqual(translate(.calendars, .calendars(.denied)), .denied)
        XCTAssertEqual(translate(.calendars, .calendars(.fullAccess)), .granted)
        XCTAssertEqual(translate(.calendars, .calendars(.writeOnly)), .denied, "«только добавление» — не полный доступ")
        XCTAssertEqual(translate(.notifications, .notifications(.notDetermined)), .notDetermined)
        XCTAssertEqual(translate(.notifications, .notifications(.denied)), .denied)
        XCTAssertEqual(translate(.notifications, .notifications(.authorized)), .granted)
        XCTAssertEqual(translate(.notifications, .notifications(.provisional)), .granted)
        XCTAssertEqual(translate(.screenRecording, .screenRecording(granted: true)), .granted)
        XCTAssertEqual(translate(.screenRecording, .screenRecording(granted: false)), .notDetermined)
        for kind in PermissionKind.allCases {
            XCTAssertEqual(translate(kind, .unreadable), .unavailable, "«чтение не удалось» у \(kind)")
        }
        XCTAssertEqual(translate(.microphone, .calendars(.fullAccess)), .unavailable, "исход чужого права")
    }

    // MARK: - Незнакомое системное значение — не ловушка и не .unknown

    func test_c01b_unknownSystemValue_isUnavailable() throws {
        let microphone = try XCTUnwrap(AVAuthorizationStatus(rawValue: 99))
        XCTAssertEqual(StatusTranslation.status(of: .microphone, reading: .microphone(microphone),
                                                promptedThisLaunch: false), .unavailable)
        let calendars = try XCTUnwrap(EKAuthorizationStatus(rawValue: 99))
        XCTAssertEqual(StatusTranslation.status(of: .calendars, reading: .calendars(calendars),
                                                promptedThisLaunch: false), .unavailable)
        let notifications = try XCTUnwrap(UNAuthorizationStatus(rawValue: 99))
        XCTAssertEqual(StatusTranslation.status(of: .notifications, reading: .notifications(notifications),
                                                promptedThisLaunch: false), .unavailable)
    }

    // MARK: - Запись экрана: после показа промпта «не выдано» читается как .denied (инвариант 6)

    func test_screenRecording_afterPrompt_readsDenied_notNotDetermined() async {
        let (reader, sut) = PermissionsHarness.reading([.screenRecording: .screenRecording(granted: false)])
        reader.answer(false, for: .screenRecording)
        let before = await sut.status(of: .screenRecording)
        XCTAssertEqual(before, .notDetermined)
        let outcome = await sut.request(.screenRecording)
        XCTAssertEqual(outcome, .denied)
        let after = await sut.status(of: .screenRecording)
        XCTAssertEqual(after, .denied, "после промпта статус уже не .notDetermined")
        reader.set(.screenRecording(granted: true), for: .screenRecording)
        let granted = await sut.status(of: .screenRecording)
        XCTAssertEqual(granted, .granted, "выданное право читается выданным")
    }

    // MARK: - Настоящее чтение: вне бандла приложения уведомления читаются как «не удалось»

    func test_realReader_notificationsOutsideAppBundle_areUnreadable() async {
        XCTAssertFalse(SystemRightsReader.hasApplicationBundle, "xctest не бандл приложения")
        let reading = await SystemRightsReader().read(.notifications)
        XCTAssertEqual(reading, .unreadable)
        let status = await SystemPermissions().status(of: .notifications)
        XCTAssertEqual(status, .unavailable)
    }
}
