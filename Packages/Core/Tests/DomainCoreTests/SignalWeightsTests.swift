//  Критерии К63 (ii), К65, К67, К68 и К72 перечня MEE-75 — сторона `domain-core` контракта
//  C-009: чистая функция «`Data` → значения», отказ на битой таблице, отсутствие умолчаний
//  после отказа, годность поставляемого файла и однократность чтения ресурса.
//
//  Текстовые половины К63 (i), (iii), (iv), К64 и К66 живут в `ModuleTextTests`.

import XCTest
import DomainCore

final class SignalWeightsTests: XCTestCase {

    // MARK: - К63 (ii). Чистая функция от Data

    /// Способ Ф плана: одни и те же байты из параллельных задач и в любом порядке вызовов
    /// дают равные значения. Ни ресурсов, ни файловой системы, ни времени функция не трогает.
    func test_k63_valuesFromData_arePureAcrossParallelTasks() async throws {
        let bytes = Data(ReferenceTables.signalWeights.utf8)
        let expected = try SignalWeights.values(from: bytes)
        let answers = await withTaskGroup(of: [SignalWeights].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (0..<125).compactMap { _ in try? SignalWeights.values(from: bytes) }
                }
            }
            var collected: [SignalWeights] = []
            for await answer in group { collected.append(contentsOf: answer) }
            return collected
        }
        XCTAssertEqual(answers.count, 1_000, "восемь задач по 125 вызовов")
        for answer in answers {
            XCTAssertEqual(answer, expected)
        }
    }

    func test_k63_valuesFromData_readSectionFiveNumbers() throws {
        let values = try SignalWeights.values(from: Data(ReferenceTables.signalWeights.utf8))
        XCTAssertEqual(values.signalTtlSeconds, 60)
        XCTAssertEqual(values.weight(for: .calendarWindow), 0.2)
        XCTAssertEqual(values.weight(for: .clientRunning), 0.4)
        XCTAssertEqual(values.weight(for: .microphoneInUse), 0.4)
        XCTAssertEqual(values.weight(for: .clientAudioOutput), 0.8)
    }

    // MARK: - К65. Восемь входов битой таблицы, ответ один

    func test_k65_brokenTable_isRefusedOnAllEightInputs() {
        for input in BrokenWeights.all {
            assertNoValueBuilt(input)
        }
        assertNoValueBuilt(BrokenWeights.negativeTtl)
        XCTAssertEqual(BrokenWeights.all.count, 8, "входов (a)…(h) ровно восемь")
    }

    /// Ключ назван в `codingPath` — отказ различим, а не «что-то пошло не так».
    func test_k65_brokenTable_namesTheKeyItRefusedOn() {
        assertCorrupted(try SignalWeights.values(from: BrokenWeights.weightOutOfRange.bytes),
                        key: "clientAudioOutput")
        assertCorrupted(try SignalWeights.values(from: BrokenWeights.zeroTtl.bytes),
                        key: "signalTtlSeconds")
        assertCorrupted(try SignalWeights.values(from: BrokenWeights.unknownSchema.bytes),
                        key: "schemaVersion")
        assertKeyNotFound(try SignalWeights.values(from: BrokenWeights.missingTtl.bytes),
                          key: "signalTtlSeconds")
    }

    // MARK: - К67. После отказа значений нет — ни нулей, ни умолчаний, ни прежних

    /// «Значений нет» и «значения нулевые» остаются разными ответами: на входе (h) значение
    /// с `signalTtlSeconds == 0` не строится вовсе, а на (g) вес не зажимается в `0...1`.
    func test_k67_afterRefusal_noValuesAreHandedOut() {
        for input in [BrokenWeights.zeroTtl, .negativeTtl, .weightOutOfRange] {
            assertNoValueBuilt(input)
        }
    }

    /// Прежний удачный набор не подставляется: функция без состояния, и отказ остаётся отказом.
    func test_k67_afterRefusal_previousGoodValuesAreNotReused() throws {
        let good = try SignalWeights.values(from: Data(ReferenceTables.signalWeights.utf8))
        XCTAssertEqual(good.signalTtlSeconds, 60)
        assertNoValueBuilt(BrokenWeights.zeroTtl)
        assertNoValueBuilt(BrokenWeights.invalidJSON)
        let again = try SignalWeights.values(from: Data(ReferenceTables.signalWeights.utf8))
        XCTAssertEqual(again, good, "годные байты после отказа читаются по-прежнему")
    }

    // MARK: - К68. Поставляемый собранным модулем файл

    /// Опровержим целиком: поставь файл с другой версией схемы, ключом сверх четырёх, весом
    /// вне `0...1` или неположительным TTL — и `current()` бросит, а тест покраснеет.
    func test_k68_suppliedResource_matchesSectionFive() throws {
        let values = try SignalWeights.current()
        XCTAssertEqual(values.schemaVersion, 1)
        XCTAssertEqual(Set(values.weights.keys), Set(MeetingSignalKind.allCases))
        XCTAssertGreaterThan(values.signalTtlSeconds, 0)
        for kind in MeetingSignalKind.allCases {
            XCTAssertTrue((0...1).contains(values.weight(for: kind)), "вес \(kind) вне 0...1")
        }
        XCTAssertEqual(values.signalTtlSeconds, 60, "числа §5 поставляются как есть")
        XCTAssertEqual(values.weight(for: .calendarWindow), 0.2)
        XCTAssertEqual(values.weight(for: .clientRunning), 0.4)
        XCTAssertEqual(values.weight(for: .microphoneInUse), 0.4)
        XCTAssertEqual(values.weight(for: .clientAudioOutput), 0.8)
    }

    // MARK: - Оснастка

    /// Построения не произошло: ни значения, ни его подмены. Если значение всё же собралось —
    /// отказ теста печатает то, что собралось, а не «ожидалась ошибка».
    private func assertNoValueBuilt(_ input: BrokenWeights,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        do {
            let built = try SignalWeights.values(from: input.bytes)
            XCTFail("на входе \(input.name) собрано значение: ttl=\(built.signalTtlSeconds), "
                    + "веса=\(built.weights)", file: file, line: line)
        } catch {
            XCTAssertTrue(error is DecodingError,
                          "ожидался отказ разбора, получено \(error)", file: file, line: line)
        }
    }
}
