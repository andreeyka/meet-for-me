//  Критерии перечня MEE-74 на `note(observed:for:)` и `changes()`: 24–30, 33–36.
//  Критерий 34 покрыт критерием 26 (повторный `note` с тем же значением).

import DomainCore
import Foundation
import XCTest
@testable import Permissions

final class NoteAndChangesTests: XCTestCase {

    // MARK: - 24, 25. После note статус равен переданному, в потоке ровно один снимок

    func test_c24_noteGranted_statusGranted_oneSnapshot() async {
        let harness = PermissionsHarness()
        let stream = harness.sut.changes()
        await harness.sut.note(observed: .granted, for: .systemAudioRecording)
        let status = await harness.sut.status(of: .systemAudioRecording)
        XCTAssertEqual(status, .granted)
        let snapshots = await Streams.take(stream, 2, within: 0.3)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.status(of: .systemAudioRecording), .granted)
    }

    func test_c25_noteDenied_statusDenied_oneSnapshot() async {
        let harness = PermissionsHarness()
        let stream = harness.sut.changes()
        await harness.sut.note(observed: .denied, for: .systemAudioRecording)
        let status = await harness.sut.status(of: .systemAudioRecording)
        XCTAssertEqual(status, .denied)
        let snapshots = await Streams.take(stream, 2, within: 0.3)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.status(of: .systemAudioRecording), .denied)
    }

    // MARK: - 26 (и 34). Повторный note с тем же значением второго снимка не даёт

    func test_c26_c34_repeatedNote_publishesNoSecondSnapshot() async {
        let harness = PermissionsHarness()
        let stream = harness.sut.changes()
        await harness.sut.note(observed: .granted, for: .systemAudioRecording)
        await harness.sut.note(observed: .granted, for: .systemAudioRecording)
        let status = await harness.sut.status(of: .systemAudioRecording)
        XCTAssertEqual(status, .granted)
        let snapshots = await Streams.take(stream, 2, within: 0.3)
        XCTAssertEqual(snapshots.count, 1)
    }

    // MARK: - 27. note меняет значение в обе стороны

    func test_c27_noteChangesBothWays_threeSnapshots() async {
        let harness = PermissionsHarness()
        let stream = harness.sut.changes()
        var seen: [PermissionStatus] = []
        for status in [PermissionStatus.granted, .denied, .granted] {
            await harness.sut.note(observed: status, for: .systemAudioRecording)
            seen.append(await harness.sut.status(of: .systemAudioRecording))
        }
        XCTAssertEqual(seen, [.granted, .denied, .granted])
        let snapshots = await Streams.take(stream, 4, within: 0.3)
        XCTAssertEqual(snapshots.map { $0.status(of: .systemAudioRecording) }, [.granted, .denied, .granted])
    }

    // MARK: - 28. note с чужим kind не меняет ничего и снимка не публикует

    func test_c28_noteForeignKind_changesNothing() async {
        let harness = PermissionsHarness([.microphone: .notDetermined, .screenRecording: .denied,
                                          .calendars: .restricted, .notifications: .unavailable,
                                          .accessibility: .granted])
        let before = await harness.sut.snapshot()
        let stream = harness.sut.changes()
        for kind in PermissionKind.allCases where kind != .systemAudioRecording {
            await harness.sut.note(observed: .granted, for: kind)
        }
        let after = await harness.sut.snapshot()
        XCTAssertEqual(after.states, before.states)
        let snapshots = await Streams.take(stream, 1, within: 0.2)
        XCTAssertEqual(snapshots.count, 0)
    }

    // MARK: - 29. note с недопустимым значением — из состояния .unknown и из .granted

    func test_c29_noteInvalidValue_changesNothing_fromUnknownAndFromGranted() async {
        let invalid: [PermissionStatus] = [.notDetermined, .restricted, .unavailable, .unknown]
        for start in [PermissionStatus.unknown, .granted] {
            let harness = PermissionsHarness()
            if start == .granted {
                await harness.sut.note(observed: .granted, for: .systemAudioRecording)
            }
            let stream = harness.sut.changes()
            for value in invalid {
                await harness.sut.note(observed: value, for: .systemAudioRecording)
                let status = await harness.sut.status(of: .systemAudioRecording)
                XCTAssertEqual(status, start, "из \(start) после note(\(value))")
            }
            let snapshots = await Streams.take(stream, 1, within: 0.2)
            XCTAssertEqual(snapshots.count, 0, "из \(start)")
        }
    }

    // MARK: - 30. Состояние не переживает создание нового экземпляра

    func test_c30_noteDoesNotSurviveNewInstance() async {
        var first: SystemPermissions? = PermissionsHarness().sut
        await first?.note(observed: .granted, for: .systemAudioRecording)
        let second = PermissionsHarness().sut
        let status = await second.status(of: .systemAudioRecording)
        XCTAssertEqual(status, .unknown)
        first = nil
        let afterRelease = await second.status(of: .systemAudioRecording)
        XCTAssertEqual(afterRelease, .unknown)
    }

    // MARK: - 33. Поток отдаёт события после подписки, начального состояния в нём нет

    func test_c33_subscriptionGetsNoHistory() async {
        let harness = PermissionsHarness()
        await harness.sut.note(observed: .granted, for: .systemAudioRecording)
        let stream = harness.sut.changes()
        let snapshots = await Streams.take(stream, 1, within: 0.1)
        XCTAssertEqual(snapshots.count, 0)
    }

    // MARK: - 35. Несколько подписчиков получают одинаковую последовательность

    func test_c35_twoSubscribers_sameSequence() async {
        let harness = PermissionsHarness()
        let first = harness.sut.changes()
        let second = harness.sut.changes()
        await harness.sut.note(observed: .granted, for: .systemAudioRecording)
        await harness.sut.note(observed: .denied, for: .systemAudioRecording)
        let got1 = await Streams.take(first, 2)
        let got2 = await Streams.take(second, 2)
        XCTAssertEqual(got1.count, 2)
        XCTAssertEqual(got1, got2)
        XCTAssertEqual(got1.map { $0.status(of: .systemAudioRecording) }, [.granted, .denied])
    }

    // MARK: - 36. Завершение итерации снимает наблюдателя

    func test_c36_leavingTheLoop_removesObserver() async {
        let harness = PermissionsHarness()
        await consumeOne(harness.sut)
        await harness.sut.note(observed: .denied, for: .systemAudioRecording)
        XCTAssertTrue(waitUntil { harness.sut.liveObserverCount == 0 },
                      "наблюдателей: \(harness.sut.liveObserverCount)")
    }

    private func consumeOne(_ sut: SystemPermissions) async {
        let stream = sut.changes()
        XCTAssertEqual(sut.liveObserverCount, 1)
        await sut.note(observed: .granted, for: .systemAudioRecording)
        let snapshots = await Streams.take(stream, 1)
        XCTAssertEqual(snapshots.map { $0.status(of: .systemAudioRecording) }, [.granted])
    }

    // MARK: - Активация приложения перечитывает снимок и публикует только изменение

    func test_activation_republishesOnlyWhenStatesChanged() async {
        let harness = PermissionsHarness([.microphone: .denied])
        _ = await harness.sut.snapshot()
        let stream = harness.sut.changes()
        harness.activation.fire()
        harness.activation.fire()
        harness.statuses.set(.granted, for: .microphone)
        harness.activation.fire()
        let snapshots = await Streams.take(stream, 2, within: 1)
        XCTAssertEqual(snapshots.map { $0.status(of: .microphone) }, [.granted],
                       "два перечитывания без изменения снимка не дали, третье — дало один")
    }
}
