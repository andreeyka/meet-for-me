//  EventsTests — подписка фасада на PermissionsPort.changes() (возврат РП, приёмка 10:15
//  UTC, находка 4). Разведено из `EventsTests.swift` по объёму (`file_length`), не по
//  смыслу — тот же приём, что `SpeakerAssignmentTests.swift`/`SpeakerAssignmentTests+
//  DeltaShch.swift`. Общие `Fixture`/`makeFixture()`/`collectEvents` — там же, не `private`.

import XCTest
@testable import DomainCore
import DomainTestKit

extension EventsTests {

    // MARK: - Смена прав: PermissionsPort.changes() → permissionsChanged + statusChanged

    /// `.permissionsChanged` уходит на КАЖДЫЙ снимок из `changes()`, `.statusChanged` — только
    /// если из-за него меняется `permissionsReady` (то же условие, что у `updateSettings`,
    /// зеркально: там менялись настройки при тех же правах, здесь — права при тех же
    /// настройках). Подписка на `facade.events()` — ДО `emit(_:)` (идиома МЕЕ-377/378);
    /// подписка самого фасада на `PermissionsPort.changes()` регистрируется в `init`, до
    /// возврата из конструктора (см. `AppFacadeImpl+PermissionsObservation.swift`), так что
    /// момент `emit(_:)` относительно готовности фоновой `Task` фасада не важен.
    func test_permissionsPortChange_publishesPermissionsChangedAndStatusChangedWhenReadinessDiffers() async {
        let fixture = makeFixture()
        let stream = fixture.facade.events()

        let deniedMicrophoneSnapshot = PermissionSnapshot(
            states: PermissionKind.allCases.map { kind in
                PermissionState(kind: kind, status: kind == .microphone ? .denied : .granted)
            },
            checkedAt: Date()
        )
        fixture.permissions.emit(deniedMicrophoneSnapshot)

        let events = await collectEvents(stream, count: 2)
        XCTAssertEqual(events.count, 2, "\(events)")
        guard case .permissionsChanged(let snapshot) = events.first else {
            return XCTFail("первым ожидался .permissionsChanged, получено \(String(describing: events.first))")
        }
        XCTAssertEqual(snapshot, deniedMicrophoneSnapshot)
        guard case .statusChanged(let status) = events.last else {
            return XCTFail("вторым ожидался .statusChanged, получено \(String(describing: events.last))")
        }
        XCTAssertEqual(status.permissionsReady, .notReady)
    }

    /// Симметричный вектор: снимок, который НЕ меняет `permissionsReady` (тут — необязательное
    /// право), даёт только `.permissionsChanged`, без `.statusChanged`.
    func test_permissionsPortChange_readinessUnaffected_publishesOnlyPermissionsChanged() async {
        let fixture = makeFixture()
        let stream = fixture.facade.events()

        let deniedScreenRecordingSnapshot = PermissionSnapshot(
            states: PermissionKind.allCases.map { kind in
                PermissionState(kind: kind, status: kind == .screenRecording ? .denied : .granted)
            },
            checkedAt: Date()
        )
        fixture.permissions.emit(deniedScreenRecordingSnapshot)

        // Таймаут короче обычного (1 с вместо 5): если бы `.statusChanged` всё же ушёл
        // (регрессия), `collectEvents(count: 2)` поймал бы его в отведённое время.
        let events = await collectEvents(stream, count: 2, timeoutSeconds: 1)
        XCTAssertEqual(events.count, 1, "\(events)")
        guard case .permissionsChanged = events.first else {
            return XCTFail("ожидался .permissionsChanged, получено \(String(describing: events.first))")
        }
    }
}
