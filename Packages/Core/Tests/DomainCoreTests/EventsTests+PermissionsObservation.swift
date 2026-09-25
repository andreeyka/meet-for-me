//  EventsTests — подписка фасада на PermissionsPort.changes() (возврат РП, приёмка 10:15
//  UTC, находка 4). Разведено из `EventsTests.swift` по объёму (`file_length`), не по
//  смыслу — тот же приём, что `SpeakerAssignmentTests.swift`/`SpeakerAssignmentTests+
//  DeltaShch.swift`. Общие `Fixture`/`makeFixture()`/`collectEvents` — там же, не `private`.
//
//  ДВА `emit(_:)` НА ВЕКТОР, НЕ ОДИН. `observePermissionsChanges` (`AppFacadeImpl+
//  PermissionsObservation.swift`) намеренно не снимает базовую готовность заранее (находка
//  CI после первой редакции — см. докстринг того файла) — самое первое пришедшее в
//  `changes()` событие только заводит `lastKnownPermissionsReadiness`, сравнивать ещё не с
//  чем, `.statusChanged` на нём не публикуется. Первый `emit(_:)` здесь — заведомо
//  «нейтральный» снимок (всё выдано), заводящий базу тем же значением, что и стартовая
//  `FakePermissionsPort(startingStatus: .granted, …)` из `makeFixture()`; второй — вектор,
//  который тест на самом деле проверяет.
//
//  `setStatus(_:for:)` ПЕРЕД КАЖДЫМ `emit(_:)`, НЕ ТОЛЬКО САМ `emit(_:)` (находка CI после
//  второй редакции): `.statusChanged`-ветка публикует `await status()`, а `status()` читает
//  ЖИВОЕ состояние `permissionsPort.snapshot()`, не значение, протолкнутое через поток
//  `changes()`, — они у фейка НЕЗАВИСИМЫ (`emit(_:)` не трогает `statuses`, только шлёт
//  значение подписчикам). Без `setStatus(_:for:)` `status()` внутри `observePermissionsChanges`
//  видел бы прежний (`.granted`) снимок независимо от того, что было `emit()`-нуто, и
//  `AppStatus.permissionsReady` внутри `.statusChanged` не совпадал бы с ожидаемым.

import XCTest
@testable import DomainCore
import DomainTestKit

extension EventsTests {

    private func allGrantedSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            states: PermissionKind.allCases.map { PermissionState(kind: $0, status: .granted) },
            checkedAt: Date()
        )
    }

    // MARK: - Смена прав: PermissionsPort.changes() → permissionsChanged + statusChanged

    /// `.permissionsChanged` уходит на КАЖДЫЙ снимок из `changes()`, `.statusChanged` — только
    /// если из-за него меняется `permissionsReady` (то же условие, что у `updateSettings`,
    /// зеркально: там менялись настройки при тех же правах, здесь — права при тех же
    /// настройках). Подписка на `facade.events()` — ДО обоих `emit(_:)` (идиома МЕЕ-377/378);
    /// подписка самого фасада на `PermissionsPort.changes()` регистрируется в `init`, до
    /// возврата из конструктора, так что момент `emit(_:)` относительно готовности фоновой
    /// `Task` фасада не важен (буфер `AsyncStream` не ограничен).
    func test_permissionsPortChange_publishesPermissionsChangedAndStatusChangedWhenReadinessDiffers() async {
        let fixture = makeFixture()
        let stream = fixture.facade.events()

        fixture.permissions.emit(allGrantedSnapshot())

        fixture.permissions.setStatus(.denied, for: .microphone)
        let deniedMicrophoneSnapshot = await fixture.permissions.snapshot()
        fixture.permissions.emit(deniedMicrophoneSnapshot)

        let events = await collectEvents(stream, count: 3)
        XCTAssertEqual(events.count, 3, "\(events)")
        guard case .permissionsChanged = events[0] else {
            return XCTFail("первым ожидался .permissionsChanged (база), получено \(events[0])")
        }
        guard case .permissionsChanged(let snapshot) = events[1] else {
            return XCTFail("вторым ожидался .permissionsChanged, получено \(events[1])")
        }
        XCTAssertEqual(snapshot, deniedMicrophoneSnapshot)
        guard case .statusChanged(let status) = events[2] else {
            return XCTFail("третьим ожидался .statusChanged, получено \(events[2])")
        }
        XCTAssertEqual(status.permissionsReady, .notReady)
    }

    /// Симметричный вектор: снимок, который НЕ меняет `permissionsReady` (тут — необязательное
    /// право), даёт только `.permissionsChanged`, без `.statusChanged`.
    func test_permissionsPortChange_readinessUnaffected_publishesOnlyPermissionsChanged() async {
        let fixture = makeFixture()
        let stream = fixture.facade.events()

        fixture.permissions.emit(allGrantedSnapshot())

        fixture.permissions.setStatus(.denied, for: .screenRecording)
        let deniedScreenRecordingSnapshot = await fixture.permissions.snapshot()
        fixture.permissions.emit(deniedScreenRecordingSnapshot)

        // Таймаут короче обычного (1 с вместо 5) у последнего ожидаемого события: если бы
        // `.statusChanged` всё же ушёл (регрессия), `collectEvents(count: 3)` поймал бы его
        // в отведённое время.
        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)
        XCTAssertEqual(events.count, 2, "\(events)")
        guard case .permissionsChanged = events[0] else {
            return XCTFail("первым ожидался .permissionsChanged (база), получено \(events[0])")
        }
        guard case .permissionsChanged = events[1] else {
            return XCTFail("вторым ожидался .permissionsChanged, получено \(events[1])")
        }
    }
}
