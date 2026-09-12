//  Ступень (в) — ограничения представимости C-001 §0.2 п. 9, общие для C-001…C-003.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Ступень выполняется после `validate()` вложенных значений и РАНЬШЕ собственных инвариантов
//  типа: собственный инвариант считает арифметику над значением, и делать это над значением,
//  которое мы уже не считаем значением своего домена, бессмысленно, а над `Date` вне диапазона
//  ещё и небезопасно — `Int(_: Double)` в Swift не насыщает и даёт ловушку, а не ошибку.
//
//  Ошибка принадлежит владельцу поля, а не контракту, в котором записано само правило:
//  `contract` и `type` берутся у типа, которому поле принадлежит, `invariant` равен нулю.

import Foundation

/// Тип, от имени которого сообщается нарушение: пара `contract` + `type` ошибки §0.1.
struct DomainOwner {
    let contract: String
    let type: String

    func fail(_ invariant: Int, _ path: String, _ message: String) -> DomainValidationError {
        DomainValidationError(contract: contract, type: type, invariant: invariant,
                              path: path, message: message)
    }

    /// Собственный инвариант типа — ступень (б).
    func check(_ condition: Bool, _ invariant: Int, _ path: String,
               _ message: @autoclosure () -> String) throws {
        guard condition else { throw fail(invariant, path, message()) }
    }

    // MARK: - Ступень (в)

    func requireFinite(_ value: Double?, _ path: String) throws {
        guard let value else { return }
        guard value.isFinite else {
            throw fail(0, path, "значение не представимо конечным Double")
        }
    }

    func requireFiniteElements(_ value: [Float]?, _ path: String) throws {
        guard let value else { return }
        for (position, element) in value.enumerated() where !element.isFinite {
            throw fail(0, "\(path)[\(position)]", "элемент не представим конечным Float")
        }
    }

    func requireDate(_ value: Date?, _ path: String) throws {
        guard let value else { return }
        guard DomainDateGrammar.isInRange(value) else {
            throw fail(0, path, "Date вне диапазона 0001-01-01T00:00:00.000Z…9999-12-31T23:59:59.999Z")
        }
    }

    func requireInt(_ value: Int?, _ path: String) throws {
        guard let value else { return }
        guard value >= -9_007_199_254_740_991, value <= 9_007_199_254_740_991 else {
            throw fail(0, path, "значение \(value) вне диапазона -(2^53 - 1)…(2^53 - 1)")
        }
    }

    /// У поля, объявленного `Int32`, диапазон типа уже диапазона §0.2 п. 9, и значения
    /// вне его в коде не существует; проверка стоит здесь ради полноты правила, а не ради вектора.
    func requireInt32(_ value: Int32, _ path: String) throws {
        try requireInt(Int(value), path)
    }
}
