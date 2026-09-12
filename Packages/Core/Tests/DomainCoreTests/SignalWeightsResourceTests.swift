//  К72: значения таблицы весов читаются один раз при инициализации, и набор их неизменяем
//  в течение жизни процесса (инвариант 22, половина `domain-core`).
//
//  Два вектора, и второй несёт основную тяжесть. Вектор (i) — байты, из которых правило не
//  строится: он ловит реализацию, перечитывающую ресурс на каждое обращение, — она отказывает
//  там, где отказывать нечему. Но он НЕ ЛОВИТ реализацию, которая перечитывает и при отказе
//  молча берёт прежние значения. Её ловит вектор (ii): валидные байты, из которых строится
//  ДРУГОЙ набор.
//
//  Чтобы вектор не был зелёным по построению, подмена доказывается здесь же: обе подменённые
//  порции байтов прогоняются через чистую функцию, и (i) отказывает, а (ii) даёт значения,
//  ОТЛИЧНЫЕ от прочитанных. Без этой пары тест зеленел бы и на подмене, которой не случилось.
//
//  Файл ресурса восстанавливается `defer`-ом: следующий тест обязан видеть дерево таким, каким
//  его положила сборка.

import XCTest
import DomainCore

final class SignalWeightsResourceTests: XCTestCase {

    func test_k72_signalWeights_areReadOnceAndNeverChange() async throws {
        let before = try SignalWeights.current()
        let url = try resourceURL()
        let original = try Data(contentsOf: url)
        defer { try? original.write(to: url) }

        try swap(to: BrokenWeights.zeroTtl.bytes, at: url)
        assertRuleDoesNotBuild(from: BrokenWeights.zeroTtl.bytes)
        XCTAssertEqual(try SignalWeights.current(), before, "вектор (i): значения те же")

        try swap(to: BrokenWeights.otherNumbers.bytes, at: url)
        let other = try SignalWeights.values(from: BrokenWeights.otherNumbers.bytes)
        XCTAssertNotEqual(other, before, "подменённые байты дают ДРУГОЙ набор — подмена состоялась")
        XCTAssertEqual(other.signalTtlSeconds, 7)
        XCTAssertEqual(other.weight(for: .clientRunning), 0.55)

        let after = try SignalWeights.current()
        XCTAssertEqual(after, before, "вектор (ii): значения те же, что прочитаны при инициализации")
        XCTAssertEqual(after.signalTtlSeconds, before.signalTtlSeconds)
        XCTAssertEqual(after.weights, before.weights)
        try await assertSameFromParallelTasks(expected: before)
    }

    // MARK: - Оснастка

    /// Значения из восьми параллельных задач равны прочитанным: второго набора не существует.
    private func assertSameFromParallelTasks(expected: SignalWeights) async throws {
        let answers = await withTaskGroup(of: SignalWeights?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? SignalWeights.current() }
            }
            var collected: [SignalWeights?] = []
            for await answer in group { collected.append(answer) }
            return collected
        }
        XCTAssertEqual(answers.count, 8)
        for answer in answers {
            XCTAssertEqual(answer, expected)
        }
    }

    private func assertRuleDoesNotBuild(from bytes: Data,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        XCTAssertThrowsError(try SignalWeights.values(from: bytes),
                             "подменённые байты обязаны быть негодными", file: file, line: line)
    }

    private func swap(to bytes: Data, at url: URL) throws {
        try bytes.write(to: url)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "подмена записана на диск")
    }

    /// Файл ресурса в собранном бандле модуля `domain-core`. Имя бандла собирает SwiftPM из
    /// имени пакета и имени таргета, а раскладка внутри бандла различается между платформами —
    /// поэтому бандл ищется по суффиксу имени, а файл внутри него обходом.
    private func resourceURL() throws -> URL {
        let roots = [Bundle.module.bundleURL.deletingLastPathComponent(), Bundle.main.bundleURL]
        for root in roots {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
            let bundles = contents.filter { $0.lastPathComponent.hasSuffix("DomainCore.bundle") }
            for bundle in bundles {
                if let found = signalWeights(in: bundle) {
                    return found
                }
            }
        }
        XCTFail("ресурс signal-weights.json не найден в собранном бандле DomainCore")
        throw CocoaError(.fileNoSuchFile)
    }

    private func signalWeights(in bundle: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: bundle,
                                                          includingPropertiesForKeys: nil) else {
            return nil
        }
        return walker
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "signal-weights.json" }
    }
}
