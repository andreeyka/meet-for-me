//  П. 157: управляющая поверхность `DomainTestKit.FakePowerPort`, названная §«Фейк для тестов»
//  C-008 дословно, включая снимок, который настоящий порт отдать не вправе. Четыре грани —
//  (а)…(г) — и три вектора.
//
//  Q47 — два разных `PowerSnapshot` у одного экземпляра: без второго ответа грань зелена
//  у реализации, принимающей снимок один раз в инициализаторе.
//  Q48 — два живых токена `.recording`, `end()` вызван на одном: без парного вектора «живых
//  не осталось» зелено у реализации, чистящей список целиком на первом же `end()`.
//  Q49 — снимок с `batteryFraction == 1.5`: основание — §«Построение значения на границе
//  модуля» C-008 дословно. «Ничего не проверяет» отличается от «тихо нормализует» только тем,
//  что утверждается КАЖДОЕ поле, а не одно.
//
//  Поток берётся ДО толчка — тот же довод и тот же образец, что у п. 156.
//  `PowerEvent` уходит в поток значением, а не байтами: `Codable` он не объявлен вовсе.
//
//  Граница, и она повторена здесь потому, что молчание о ней читается как её отсутствие:
//  инварианты 2—9 C-008 — обязанность порта, проверяются тестами реализатора, и ни одно
//  утверждение этого файла о них не делается. Грань (г) утверждает НАБЛЮДАЕМОСТЬ списка живых
//  токенов, а не то, что ограничение снялось: ограничений у фейка нет вовсе.

import XCTest
import DomainCore
import DomainTestKit

final class FakePowerPortTests: XCTestCase {

    // MARK: - (а) снимок задаётся и меняется на лету — вектор Q47

    func test_p157_fakePowerPort_snapshotIsSetAndChangedOnTheFly() async {
        // Вектор содержания: батареи в машине нет.
        let first = makeSnapshot(source: .ac, fraction: nil, thermal: .nominal)
        let port = FakePowerPort(snapshot: first)
        let read = await port.snapshot()
        XCTAssertEqual(read, first, "первый ответ — заданное")
        XCTAssertNil(read.batteryFraction, "nil доходит как nil")

        // Q47: смена на лету — ДВА РАЗНЫХ ответа у одного экземпляра.
        let second = makeSnapshot(source: .battery, fraction: 0.42, thermal: .critical)
        port.setSnapshot(second)
        let again = await port.snapshot()
        XCTAssertEqual(again, second, "второй ответ — новое значение")
        XCTAssertNotEqual(again, first, "а не первое")
        XCTAssertEqual(again.source, .battery)
        XCTAssertEqual(again.thermalPressure, .critical)
    }

    // MARK: - (б) любой PowerEvent в поток events()

    func test_p157_fakePowerPort_pushesAnyEventIntoStream() async {
        let port = FakePowerPort(snapshot: makeSnapshot(source: .ac, fraction: 0.5, thermal: .nominal))
        let stream = port.events()          // поток берётся ДО толчка
        let pushed: [PowerEvent] = [
            .willSleep,
            .didWake,
            .powerSourceChanged(.battery),
            .thermalPressureChanged(.critical)
        ]
        for event in pushed { port.emit(event) }
        port.finishEvents()
        var received: [PowerEvent] = []
        for await event in stream { received.append(event) }
        XCTAssertEqual(received, pushed, "утверждается последовательность, а не множество")
        XCTAssertEqual(Array(received.prefix(2)), [.willSleep, .didWake], "`.willSleep` → `.didWake` подряд")
    }

    // MARK: - (в) список живых токенов с их reason и label

    func test_p157_fakePowerPort_liveActivitiesCarryReasonAndLabel() async {
        let port = FakePowerPort(snapshot: makeSnapshot(source: .ac, fraction: 0.5, thermal: .nominal))
        XCTAssertTrue(port.liveActivities.isEmpty, "до первого beginActivity живых нет")
        // Одного токена мало: список из одного элемента не отличает «список живых»
        // от «последний взятый».
        _ = await port.beginActivity(reason: .recording, label: "запись встречи")
        _ = await port.beginActivity(reason: .processing, label: "фоновая обработка")
        let live = port.liveActivities
        XCTAssertEqual(live.count, 2, "оба токена живы в одном экземпляре")
        XCTAssertEqual(live.map(\.reason), [.recording, .processing], "каждый со своим reason")
        XCTAssertEqual(live.map(\.label), ["запись встречи", "фоновая обработка"], "и со своим label")
    }

    // MARK: - (г) после остановки записи живых токенов не осталось — вектор Q48

    func test_p157_fakePowerPort_endRemovesOnlyItsOwnToken() async {
        let port = FakePowerPort(snapshot: makeSnapshot(source: .ac, fraction: 0.5, thermal: .nominal))
        let first = await port.beginActivity(reason: .recording, label: "первая")
        let second = await port.beginActivity(reason: .recording, label: "вторая")
        XCTAssertEqual(port.liveActivities.count, 2)

        // Q48: `end()` на одном из двух живых `.recording` оставляет в списке второй.
        first.end()
        XCTAssertEqual(port.liveActivities.map(\.label), ["вторая"], "убран ровно свой токен")
        second.end()
        XCTAssertTrue(port.liveActivities.isEmpty, "живых токенов не осталось")
    }

    // MARK: - Снимок, который настоящий порт отдать не вправе — вектор Q49

    func test_p157_fakePowerPort_snapshotNoRealPortMayReturn() async throws {
        let broken = PowerSnapshot(
            source: .battery,
            batteryFraction: 1.5,
            isLowPowerModeEnabled: false,
            thermalPressure: .nominal,
            checkedAt: moment)
        let port = FakePowerPort(snapshot: broken)
        let read = await port.snapshot()
        let fraction = try XCTUnwrap(read.batteryFraction)
        XCTAssertEqual(fraction, 1.5, "зажатия в 0...1 фейк не делает")
        XCTAssertEqual(read.source, .battery, "каждое поле равно переданному")
        XCTAssertFalse(read.isLowPowerModeEnabled)
        XCTAssertEqual(read.thermalPressure, .nominal)
        XCTAssertEqual(read.checkedAt, moment)
        XCTAssertEqual(read, broken, "значение не приводится ни к чему")
    }

    // MARK: - Оснастка

    private var moment: Date { date(milliseconds: 1_757_000_000_000) }

    private func makeSnapshot(source: PowerSource,
                              fraction: Double?,
                              thermal: ThermalPressure) -> PowerSnapshot {
        PowerSnapshot(source: source,
                      batteryFraction: fraction,
                      isLowPowerModeEnabled: false,
                      thermalPressure: thermal,
                      checkedAt: moment)
    }
}
