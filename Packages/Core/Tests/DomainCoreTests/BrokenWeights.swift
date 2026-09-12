//  Восемь входов К65: байты `signal-weights.json`, из которых нельзя построить правило,
//  действующее по контракту C-009.
//
//  (a)…(f) отвергает `DomainJSON` и сам разбор формата; (g) и (h) — правила §«Поведение»:
//  у них JSON валиден, а таблица всё равно битая. Разведение важно: без (g) и (h) проверялся
//  бы декодер, а не контракт.
//
//  Все восемь строятся из одного эталона одной заменой каждый — так видно, чем именно вход
//  отличается от годного, и эталон не расходится с §5 по недосмотру.

import Foundation

struct BrokenWeights {

    let name: String
    let text: String

    var bytes: Data { Data(text.utf8) }

    private static let base = ReferenceTables.signalWeights

    /// (a) невалидный JSON — документ обрывается на середине.
    static let invalidJSON = BrokenWeights(
        name: "(a) невалидный JSON",
        text: String(base.dropLast(1)))

    /// (b) неизвестная версия схемы.
    static let unknownSchema = BrokenWeights(
        name: "(b) schemaVersion == 2",
        text: ReferenceTables.withSchemaVersion(2, in: base))

    /// (c) версии схемы нет вовсе.
    static let missingSchema = BrokenWeights(
        name: "(c) schemaVersion отсутствует",
        text: ReferenceTables.withoutSchemaVersion(base))

    /// (d) повторяющийся ключ — отвергается байтовым пре-проходом `DomainJSON`.
    static let duplicateKey = BrokenWeights(
        name: "(d) повторяющийся ключ",
        text: base.replacingOccurrences(
            of: "  \"signalTtlSeconds\": 60,",
            with: "  \"signalTtlSeconds\": 60,\n  \"signalTtlSeconds\": 60,"))

    /// (e) число, не представимое конечным `Double`.
    static let nonFiniteNumber = BrokenWeights(
        name: "(e) 1e400 в весе",
        text: base.replacingOccurrences(of: "\"clientRunning\": 0.4",
                                        with: "\"clientRunning\": 1e400"))

    /// (f) отсутствующее обязательное поле.
    static let missingTtl = BrokenWeights(
        name: "(f) нет signalTtlSeconds",
        text: base.replacingOccurrences(of: "  \"signalTtlSeconds\": 60,\n", with: ""))

    /// (g) вес вне `0...1` — инвариант 11 объявляет такой сигнал невалидным.
    static let weightOutOfRange = BrokenWeights(
        name: "(g) clientAudioOutput == 1.5",
        text: base.replacingOccurrences(of: "\"clientAudioOutput\": 0.8",
                                        with: "\"clientAudioOutput\": 1.5"))

    /// (h) неположительный TTL: правило актуальности не действует ни на одном входе.
    static let zeroTtl = BrokenWeights(
        name: "(h) signalTtlSeconds == 0",
        text: base.replacingOccurrences(of: "\"signalTtlSeconds\": 60",
                                        with: "\"signalTtlSeconds\": 0"))

    /// Вторая половина (h).
    static let negativeTtl = BrokenWeights(
        name: "(h) signalTtlSeconds == -1",
        text: base.replacingOccurrences(of: "\"signalTtlSeconds\": 60",
                                        with: "\"signalTtlSeconds\": -1"))

    /// Ровно восемь входов (a)…(h); вторая половина (h) подаётся отдельно.
    static let all: [BrokenWeights] = [
        invalidJSON, unknownSchema, missingSchema, duplicateKey,
        nonFiniteNumber, missingTtl, weightOutOfRange, zeroTtl
    ]

    /// Валидные байты с другими числами — вектор (ii) критерия К72.
    static let otherNumbers = BrokenWeights(
        name: "валидная таблица с другими числами",
        text: base
            .replacingOccurrences(of: "\"clientRunning\": 0.4", with: "\"clientRunning\": 0.55")
            .replacingOccurrences(of: "\"signalTtlSeconds\": 60", with: "\"signalTtlSeconds\": 7"))
}
