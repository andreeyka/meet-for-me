//  DomainValidationError — тип ошибки нарушения инварианта, C-001 §0.1.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  В контракт входят только contract, type, invariant и path: текст message нестабилен
//  и сравнению не подлежит (§0.1). Отсекающего механизма на поле invariant нет —
//  это решение §0.1 (IR-043), а не пропуск: поле читается сырым decode.

import Foundation

/// Нарушение инварианта контракта C-001…C-003.
public struct DomainValidationError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    /// `"C-001"` | `"C-002"` | `"C-003"`.
    public let contract: String
    /// Имя типа, который проверяет инвариант: `"MeetingEvent"`, `"Transcript.Word"`, …
    public let type: String
    /// Номер инварианта названного контракта; `0` — общее ограничение представимости, §0.2 п. 9.
    public let invariant: Int
    /// Путь до поля от корня значения — от того типа, который проверяет инвариант.
    public let path: String
    /// Одна фраза с фактическим значением или причиной. В контракт не входит.
    public let message: String

    public init(contract: String, type: String, invariant: Int, path: String, message: String) {
        self.contract = contract
        self.type = type
        self.invariant = invariant
        self.path = path
        self.message = message
    }

    /// Ровно: `"\(contract).\(type) инв. \(invariant), \(path): \(message)"`.
    public var description: String {
        "\(contract).\(type) инв. \(invariant), \(path): \(message)"
    }
}

/// Тип, проверяющий инварианты своего контракта.
public protocol DomainValidatable {
    /// Бросает `DomainValidationError` на первом нарушении.
    func validate() throws
}
