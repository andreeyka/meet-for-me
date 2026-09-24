//  Критерии перечня MEE-74: форма снимка и согласованность (1.а, 3, 4, 5, 6), ветки `.unknown`
//  до первого `note` (22, 23, 49).
//
//  Часть прогоняется на настоящем порте (`SystemPermissions()`): чтение статусов у системы промпта
//  не поднимает, а право уведомлений в процессе без бандла приложения читается как «не удалось».

import DomainCore
import Foundation
import XCTest
@testable import Permissions

final class SnapshotTests: XCTestCase {

    static let reachable: [PermissionKind: [PermissionStatus]] = [
        .microphone: [.notDetermined, .granted, .denied, .restricted, .unavailable],
        .screenRecording: [.notDetermined, .granted, .denied, .restricted, .unavailable],
        .calendars: [.notDetermined, .granted, .denied, .restricted, .unavailable],
        .notifications: [.notDetermined, .granted, .denied, .restricted, .unavailable],
        .accessibility: [.granted, .denied, .restricted, .unavailable]
    ]

    // MARK: - 1.а. Подставленный статус порт и отдаёт — на достижимых клетках матрицы §2.1

    func test_c01a_substitutedStatus_isWhatPortReturns() async {
        for (kind, statuses) in Self.reachable {
            for status in statuses {
                let harness = PermissionsHarness([kind: status])
                let got = await harness.sut.status(of: kind)
                XCTAssertEqual(got, status, "\(kind)")
                let snapshot = await harness.sut.snapshot()
                XCTAssertEqual(snapshot.status(of: kind), status, "\(kind) в снимке")
            }
        }
    }

    // MARK: - 3, 4. По одному элементу на каждый kind, без дубликатов

    func test_c03_c04_snapshotHasEveryKindOnce_onRealPort() async {
        let snapshot = await SystemPermissions().snapshot()
        XCTAssertEqual(snapshot.states.count, 6)
        XCTAssertEqual(Set(snapshot.states.map(\.kind)), Set(PermissionKind.allCases))
        XCTAssertEqual(snapshot.states.map(\.kind).count, Set(snapshot.states.map(\.kind)).count, "дубликатов нет")
    }

    func test_c03_c04_snapshotHasEveryKindOnce_onSubstitutedSources() async {
        let snapshot = await PermissionsHarness([.microphone: .granted]).sut.snapshot()
        XCTAssertEqual(snapshot.states.count, 6)
        XCTAssertEqual(Set(snapshot.states.map(\.kind)), Set(PermissionKind.allCases))
        XCTAssertEqual(snapshot.states.map(\.kind).count, 6)
    }

    // MARK: - 5. Снимок и status(of:) совпадают без вмешательства между вызовами

    func test_c05_snapshotStatusEqualsStatusOf() async {
        let harness = PermissionsHarness([.microphone: .granted, .screenRecording: .notDetermined,
                                          .calendars: .restricted, .notifications: .unavailable,
                                          .accessibility: .denied])
        await harness.sut.note(observed: .granted, for: .systemAudioRecording)
        let snapshot = await harness.sut.snapshot()
        for kind in PermissionKind.allCases {
            let direct = await harness.sut.status(of: kind)
            XCTAssertEqual(snapshot.status(of: kind), direct, "\(kind)")
        }
        let real = SystemPermissions()
        let realSnapshot = await real.snapshot()
        for kind in PermissionKind.allCases {
            let direct = await real.status(of: kind)
            XCTAssertEqual(realSnapshot.status(of: kind), direct, "\(kind) на настоящем порте")
        }
    }

    // MARK: - 6. checkedAt — время снимка, а не наблюдения

    func test_c06_checkedAt_isSnapshotTime_notNoteTime() async throws {
        // MEE-379 (аудит MEE-377, п.2, возврат РП 24.09 18:05): фейковые часы вместо реальной
        // паузы — `noteTime`/`snapshotCall` разведены явным сдвигом, не гонкой с планировщиком.
        let clock = ManualClock()
        let harness = PermissionsHarness(now: clock.now)
        let noteTime = clock.now()
        await harness.sut.note(observed: .granted, for: .systemAudioRecording)
        clock.advance(by: 1)
        let snapshotCall = clock.now()
        let snapshot = await harness.sut.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.checkedAt, snapshotCall)
        XCTAssertGreaterThan(snapshot.checkedAt, noteTime)
    }

    // MARK: - 23. У свежего порта право на системный звук — .unknown обоими путями

    func test_c23_freshPort_systemAudioIsUnknown_bothWays() async {
        for sut in [SystemPermissions(), PermissionsHarness().sut] {
            let direct = await sut.status(of: .systemAudioRecording)
            XCTAssertEqual(direct, .unknown)
            let snapshot = await sut.snapshot()
            XCTAssertEqual(snapshot.status(of: .systemAudioRecording), .unknown)
        }
    }

    // MARK: - 22, 49. Системный звук не принимает .notDetermined, .restricted, .unavailable

    func test_c22_c49_systemAudio_onlyUnknownGrantedDenied() async {
        let harness = PermissionsHarness()
        let allowed: Set<PermissionStatus> = [.unknown, .granted, .denied]
        var seen: [PermissionStatus] = []
        seen.append(await harness.sut.status(of: .systemAudioRecording))
        await harness.sut.note(observed: .granted, for: .systemAudioRecording)
        seen.append(await harness.sut.status(of: .systemAudioRecording))
        await harness.sut.note(observed: .denied, for: .systemAudioRecording)
        seen.append(await harness.sut.status(of: .systemAudioRecording))
        for status in [PermissionStatus.notDetermined, .restricted, .unavailable, .unknown] {
            await harness.sut.note(observed: status, for: .systemAudioRecording)
            seen.append(await harness.sut.status(of: .systemAudioRecording))
        }
        await harness.sut.note(observed: .granted, for: .microphone)
        seen.append(await harness.sut.status(of: .systemAudioRecording))
        XCTAssertEqual(seen.count, 8)
        XCTAssertTrue(seen.allSatisfy { allowed.contains($0) }, "\(seen)")
        XCTAssertEqual(seen[0], .unknown)
        XCTAssertEqual(seen[1], .granted)
        XCTAssertEqual(seen[2], .denied)
    }
}
