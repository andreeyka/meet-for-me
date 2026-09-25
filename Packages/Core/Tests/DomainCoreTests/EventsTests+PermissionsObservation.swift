//  EventsTests — подписка фасада на PermissionsPort.changes() (возврат РП, приёмка 10:15
//  UTC, находка 4). Разведено из `EventsTests.swift` по объёму (`file_length`), не по
//  смыслу — тот же приём, что `SpeakerAssignmentTests.swift`/`SpeakerAssignmentTests+
//  DeltaShch.swift`. Общие `Fixture`/`makeFixture()`/`collectEvents` — там же, не `private`.
//
//  ДВА `emit(_:)` НА ВЕКТОР, НЕ ОДИН. Первый `emit(_:)` — сам по себе отдельный вектор
//  (возврат РП, повторная приёмка 11:05 UTC, находка 1): настоящий `PermissionsPort`
//  (`Permissions/Broadcaster.swift`, C-007) начального снимка при подписке не шлёт, только
//  последующие изменения, — значит и самый первый снимок из `changes()` уже настоящая смена
//  относительно состояния на старте, и `.statusChanged` обязан уйти уже на нём
//  (`handlePermissionsChange`, `AppFacadeImpl+PermissionsObservation.swift`, `lastKnown...
//  == nil` трактуется как «изменилось»). Второй `emit(_:)` — вектор, названный в имени теста.
//
//  `setStatus(_:for:)` ПЕРЕД КАЖДЫМ `emit(_:)`, НЕ ТОЛЬКО САМ `emit(_:)` (находка CI после
//  второй редакции): `.statusChanged`-ветка публикует `await status()`, а `status()` читает
//  ЖИВОЕ состояние `permissionsPort.snapshot()`, не значение, протолкнутое через поток
//  `changes()`, — они у фейка НЕЗАВИСИМЫ (`emit(_:)` не трогает `statuses`, только шлёт
//  значение подписчикам). Без `setStatus(_:for:)` `status()` внутри обработчика видел бы
//  прежний (`.granted`) снимок независимо от того, что было `emit()`-нуто, и
//  `AppStatus.permissionsReady` внутри `.statusChanged` не совпадал бы с ожидаемым.
//
//  СНАЧАЛА СОБРАТЬ ПЕРВУЮ ПАРУ СОБЫТИЙ, ПОТОМ МЕНЯТЬ ЖИВОЕ СОСТОЯНИЕ ДЛЯ ВТОРОЙ (находка CI
//  после третьей редакции): `setStatus(_:for:)`/`emit(_:)` — синхронные вызовы на стороне
//  теста, они не ждут, пока фоновая `Task` фасада успеет обработать УЖЕ буферизованное
//  первое событие. Если второй `setStatus(_:for:)` выполняется раньше, чем обработчик
//  первого события дошёл до своего `await status()`, тот читает УЖЕ изменённое (вторым
//  вызовом) живое состояние — «первый» `.statusChanged` получает ответ, предназначенный
//  второму. `await collectEvents(...)` на первой паре — барьер: он гарантированно не
//  возвращается, пока оба события первой пары не обработаны, значит `status()` внутри них
//  успел прочитать состояние ДО второго `setStatus(_:for:)`.

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

    /// `.permissionsChanged` уходит на КАЖДЫЙ снимок из `changes()`. `.statusChanged` — на
    /// первом снимке безусловно (находка 1, см. докстринг файла) и на втором, только если
    /// из-за него меняется `permissionsReady` (то же условие, что у `updateSettings`,
    /// зеркально: там менялись настройки при тех же правах, здесь — права при тех же
    /// настройках). Подписка на `facade.events()` — ДО обоих `emit(_:)` (идиома МЕЕ-377/378);
    /// подписка самого фасада на `PermissionsPort.changes()` регистрируется в `init`, до
    /// возврата из конструктора, так что момент `emit(_:)` относительно готовности фоновой
    /// `Task` фасада не важен (буфер `AsyncStream` не ограничен).
    func test_permissionsPortChange_publishesPermissionsChangedAndStatusChangedWhenReadinessDiffers() async {
        let fixture = makeFixture()
        let stream = fixture.facade.events()

        fixture.permissions.emit(allGrantedSnapshot())

        let firstEvents = await collectEvents(stream, count: 2)
        XCTAssertEqual(firstEvents.count, 2, "\(firstEvents)")
        guard case .permissionsChanged = firstEvents[0] else {
            return XCTFail("первым ожидался .permissionsChanged, получено \(firstEvents[0])")
        }
        guard case .statusChanged(let firstStatus) = firstEvents[1] else {
            return XCTFail("вторым ожидался .statusChanged (первый снимок — безусловно), получено \(firstEvents[1])")
        }
        XCTAssertEqual(firstStatus.permissionsReady, .ready)

        fixture.permissions.setStatus(.denied, for: .microphone)
        let deniedMicrophoneSnapshot = await fixture.permissions.snapshot()
        fixture.permissions.emit(deniedMicrophoneSnapshot)

        let secondEvents = await collectEvents(stream, count: 2)
        XCTAssertEqual(secondEvents.count, 2, "\(secondEvents)")
        guard case .permissionsChanged(let snapshot) = secondEvents[0] else {
            return XCTFail("первым (второй пары) ожидался .permissionsChanged, получено \(secondEvents[0])")
        }
        XCTAssertEqual(snapshot, deniedMicrophoneSnapshot)
        guard case .statusChanged(let status) = secondEvents[1] else {
            return XCTFail("вторым (второй пары) ожидался .statusChanged, получено \(secondEvents[1])")
        }
        XCTAssertEqual(status.permissionsReady, .notReady)
    }

    /// Симметричный вектор: ВТОРОЙ снимок не меняет `permissionsReady` (тут — необязательное
    /// право) — даёт только `.permissionsChanged`, без `.statusChanged`. Первый снимок
    /// по-прежнему безусловно даёт оба события (находка 1).
    func test_permissionsPortChange_readinessUnaffected_publishesOnlyPermissionsChanged() async {
        let fixture = makeFixture()
        let stream = fixture.facade.events()

        fixture.permissions.emit(allGrantedSnapshot())

        let firstEvents = await collectEvents(stream, count: 2)
        XCTAssertEqual(firstEvents.count, 2, "\(firstEvents)")
        guard case .permissionsChanged = firstEvents[0] else {
            return XCTFail("первым ожидался .permissionsChanged, получено \(firstEvents[0])")
        }
        guard case .statusChanged = firstEvents[1] else {
            return XCTFail("вторым ожидался .statusChanged (первый снимок — безусловно), получено \(firstEvents[1])")
        }

        fixture.permissions.setStatus(.denied, for: .screenRecording)
        let deniedScreenRecordingSnapshot = await fixture.permissions.snapshot()
        fixture.permissions.emit(deniedScreenRecordingSnapshot)

        // Таймаут короче обычного (1 с вместо 5) у второго ожидаемого события: если бы
        // `.statusChanged` всё же ушёл (регрессия), `collectEvents(count: 2)` поймал бы его
        // в отведённое время.
        let secondEvents = await collectEvents(stream, count: 2, timeoutSeconds: 1)
        XCTAssertEqual(secondEvents.count, 1, "\(secondEvents)")
        guard case .permissionsChanged = secondEvents[0] else {
            return XCTFail("ожидался .permissionsChanged, получено \(secondEvents[0])")
        }
    }
}
