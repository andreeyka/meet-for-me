//  П. 156: управляющая поверхность `DomainTestKit.FakePermissionsPort`, названная
//  §«Фейк для тестов» C-007 дословно. Шесть граней — (а)…(е) — и два вектора сверх них.
//
//  Q45 — счётчики на ДВУХ РАЗНЫХ правах в одном экземпляре: суммарный счётчик отличается от
//  счётчика «по правам» только на этом входе.
//  Q46 — ответ `request(_:)` задан НЕ СОГЛАСОВАННО со статусом: вход сознательно нарушает
//  инварианты 3 и 4 C-007, потому что фейк ими не связан, и в этом весь смысл вектора.
//
//  Поток берётся ДО толчка — иначе утверждение зелено или мигает по причине, к фейку отношения
//  не имеющей. Форма взята у `test_p148_fakeProcessMonitorPort_pushesSignalNoRealPortMayEmit`.
//
//  Граница, и она повторена здесь потому, что молчание о ней читается как её отсутствие:
//  инварианты C-007 — обязанность порта, проверяются тестами реализатора, и ни одно утверждение
//  этого файла о них не делается. В частности здесь НЕ утверждается ни полнота снимка
//  (инвариант 1), ни согласие двух путей (инвариант 2), ни что отвечает `request` при заданном
//  статусе (инварианты 3 и 4), ни что `.accessibility` не бывает `.notDetermined` (инвариант 5).
//  Утверждается «отдаёт заданное», а не «согласны между собой».

import XCTest
import DomainCore
import DomainTestKit

final class FakePermissionsPortTests: XCTestCase {

    // MARK: - (а) стартовый статус каждому PermissionKind, включая .unknown

    func test_p156_fakePermissionsPort_startingStatusForEveryKind() async throws {
        let wanted: [PermissionKind: PermissionStatus] = [
            .microphone: .granted,
            .systemAudioRecording: .unknown,
            .screenRecording: .denied,
            .calendars: .restricted,
            .notifications: .notDetermined,
            .accessibility: .unavailable
        ]
        XCTAssertTrue(wanted.values.contains(.unknown), "среди заданных значений есть .unknown")
        let port = makePort()
        for kind in PermissionKind.allCases {
            let status = try XCTUnwrap(wanted[kind], "право без заданного статуса: \(kind)")
            port.setStatus(status, for: kind)
        }
        let snapshot = await port.snapshot()
        XCTAssertEqual(snapshot.states.count, PermissionKind.allCases.count, "шесть прав, а не одно")
        for kind in PermissionKind.allCases {
            let expected = try XCTUnwrap(wanted[kind])
            XCTAssertEqual(snapshot.status(of: kind), expected, "snapshot() отдаёт заданное: \(kind)")
            let direct = await port.status(of: kind)
            XCTAssertEqual(direct, expected, "status(of:) отдаёт заданное: \(kind)")
        }
        XCTAssertEqual(snapshot.checkedAt, moment, "checkedAt тоже вход теста, а не решение фейка")
    }

    // MARK: - (б) чем отвечает request(_:) — вектор Q46

    func test_p156_fakePermissionsPort_requestOutcomeIsAskedNotDerived() async {
        let port = makePort()
        // Q46: статус и ответ заданы НЕ СОГЛАСОВАННО. Реализация, выводящая ответ из статуса,
        // краснеет ровно здесь и зелена на всяком согласованном векторе.
        port.setStatus(.granted, for: .microphone)
        port.setRequestOutcome(.cannotPrompt, for: .microphone)
        port.setStatus(.denied, for: .calendars)
        port.setRequestOutcome(.granted, for: .calendars)
        port.setStatus(.unknown, for: .systemAudioRecording)
        port.setRequestOutcome(.promptOnUse, for: .systemAudioRecording)
        port.setStatus(.notDetermined, for: .notifications)
        port.setRequestOutcome(.denied, for: .notifications)

        let onGranted = await port.request(.microphone)
        XCTAssertEqual(onGranted, .cannotPrompt, "при .granted отдан заданный .cannotPrompt")
        let onDenied = await port.request(.calendars)
        XCTAssertEqual(onDenied, .granted, "при .denied отдан заданный .granted")
        let onUnknown = await port.request(.systemAudioRecording)
        XCTAssertEqual(onUnknown, .promptOnUse, "оба случая, которых нет у PermissionStatus")
        let onNotDetermined = await port.request(.notifications)
        XCTAssertEqual(onNotDetermined, .denied)

        let afterRequest = await port.status(of: .microphone)
        XCTAssertEqual(afterRequest, .granted, "request не пишет статус: заданное не тронуто")
    }

    // MARK: - (в) новый PermissionSnapshot в поток changes()

    func test_p156_fakePermissionsPort_pushesSnapshotIntoChanges() async {
        let port = makePort()
        let stream = port.changes()          // поток берётся ДО толчка
        let first = fullSnapshot(status: .denied)
        let second = fullSnapshot(status: .granted)
        port.emit(first)
        port.emit(second)
        port.finishChanges()
        var received: [PermissionSnapshot] = []
        for await snapshot in stream { received.append(snapshot) }
        XCTAssertEqual(received, [first, second], "значение доходит неизменённым и по порядку")

        // Толчок в поток состояния `snapshot()` не трогает: обе стороны задаются тестом порознь,
        // и ни одна не выводится из другой. Это устройство фейка, а не утверждение об инв. 8.
        let state = await port.status(of: .microphone)
        XCTAssertEqual(state, .notDetermined, "засев init остался тем, чем был")
    }

    // MARK: - (г) openSettings(for:) бросит названную ошибку

    func test_p156_fakePermissionsPort_openSettingsThrowsWhatTestAsked() async {
        let port = makePort()
        let asked = PermissionsError.settingsPaneUnavailable(kind: .screenRecording)
        port.failOpenSettings(with: asked, for: .screenRecording)
        do {
            try await port.openSettings(for: .screenRecording)
            XCTFail("ожидался отказ \(asked)")
        } catch let error as PermissionsError {
            XCTAssertEqual(error, asked, "тип ошибки и её связанное значение")
        } catch {
            XCTFail("ожидался PermissionsError, получено \(error)")
        }
        // Парный вектор: право, которому отказ не задан, не бросает.
        await assertDoesNotThrow(port, kind: .microphone)
        port.failOpenSettings(with: nil, for: .screenRecording)
        await assertDoesNotThrow(port, kind: .screenRecording)
    }

    // MARK: - (д) счётчики по правам — вектор Q45

    func test_p156_fakePermissionsPort_countsCallsPerKind() async {
        let port = makePort()
        // Q45: два разных права в одном экземпляре. На одном они совпали бы у любой реализации.
        _ = await port.request(.microphone)
        _ = await port.request(.microphone)
        _ = await port.request(.calendars)
        XCTAssertEqual(port.requestCallCount(for: .microphone), 2, "по правам, а не суммарно")
        XCTAssertEqual(port.requestCallCount(for: .calendars), 1)
        XCTAssertEqual(port.requestCallCount(for: .notifications), 0)

        // Счётчик растёт и там, где вызов бросил: иначе (д) на праве с отказом считает пустоту.
        port.failOpenSettings(with: .settingsPaneUnavailable(kind: .calendars), for: .calendars)
        _ = try? await port.openSettings(for: .calendars)
        _ = try? await port.openSettings(for: .calendars)
        _ = try? await port.openSettings(for: .microphone)
        XCTAssertEqual(port.openSettingsCallCount(for: .calendars), 2, "бросок вызова не отменяет")
        XCTAssertEqual(port.openSettingsCallCount(for: .microphone), 1)

        await port.note(observed: .granted, for: .systemAudioRecording)
        await port.note(observed: .denied, for: .systemAudioRecording)
        await port.note(observed: .granted, for: .microphone)
        XCTAssertEqual(port.noteCallCount(for: .systemAudioRecording), 2)
        XCTAssertEqual(port.noteCallCount(for: .microphone), 1)
        XCTAssertEqual(port.noteCallCount(for: .calendars), 0)
    }

    // MARK: - (е) isLaunchAtLoginEnabled переключается

    func test_p156_fakePermissionsPort_launchAtLoginToggles() async throws {
        let port = makePort()
        let initial = await port.isLaunchAtLoginEnabled()
        XCTAssertFalse(initial, "стартовое значение")
        try await port.setLaunchAtLogin(true)
        let enabled = await port.isLaunchAtLoginEnabled()
        XCTAssertTrue(enabled)
        try await port.setLaunchAtLogin(false)
        let disabled = await port.isLaunchAtLoginEnabled()
        XCTAssertFalse(disabled, "и обратно")
    }

    // MARK: - Оснастка

    private var moment: Date { date(milliseconds: 1_757_000_000_000) }

    private func makePort() -> FakePermissionsPort {
        FakePermissionsPort(startingStatus: .notDetermined, startingOutcome: .denied, checkedAt: moment)
    }

    /// Полный снимок — по одному состоянию на каждое право. Полным он взят намеренно: вопрос
    /// о том, вправе ли фейк отдать снимок, нарушающий инвариант 1, открыт и принадлежит
    /// владельцу C-007, а не этому тесту.
    private func fullSnapshot(status: PermissionStatus) -> PermissionSnapshot {
        PermissionSnapshot(states: PermissionKind.allCases.map { PermissionState(kind: $0, status: status) },
                           checkedAt: moment)
    }

    private func assertDoesNotThrow(_ port: FakePermissionsPort,
                                    kind: PermissionKind,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) async {
        do {
            try await port.openSettings(for: kind)
        } catch {
            XCTFail("отказ не задан, а порт всё равно бросил: \(error)", file: file, line: line)
        }
    }
}
