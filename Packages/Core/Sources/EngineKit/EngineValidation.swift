//  EngineOwner — ступень (в) C-001 §0.2 п. 9, представимость чисел, зеркало
//  `domain-core`'s `DomainOwner` (DomainRepresentable.swift): та структура не публичная,
//  через границу модуля её не унести. `DomainValidationError`/`DomainValidatable` сами
//  публичны (DomainCore) и используются отсюда как есть.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)

import DomainCore

struct EngineOwner {
    let contract: String
    let type: String

    func fail(_ invariant: Int, _ path: String, _ message: String) -> DomainValidationError {
        DomainValidationError(contract: contract, type: type, invariant: invariant,
                              path: path, message: message)
    }

    /// Ступень (в): целые — диапазон §0.2 п. 9 (представимость Double без потери точности).
    func requireInt(_ value: Int?, _ path: String) throws {
        guard let value else { return }
        guard value >= -9_007_199_254_740_991, value <= 9_007_199_254_740_991 else {
            throw fail(0, path, "значение \(value) вне диапазона -(2^53 - 1)…(2^53 - 1)")
        }
    }

    func requireFiniteElements(_ value: [Float], _ path: String) throws {
        for (position, element) in value.enumerated() where !element.isFinite {
            throw fail(0, "\(path)[\(position)]", "элемент не представим конечным Float")
        }
    }
}
