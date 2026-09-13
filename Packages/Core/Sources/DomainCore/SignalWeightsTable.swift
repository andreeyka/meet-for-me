//  SignalWeightsTable — DTO таблицы весов сигналов C-009, §5 «`signal-weights.json`».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Этот тип есть форма файла и только форма: он хранит ровно то, что в файле написано,
//  включая набор ключей объекта `weights` — теми строками, какими они там стоят. Правила,
//  по которым таблица объявляется битой (вес вне `0...1`, неположительный `signalTtlSeconds`,
//  набор ключей, не равный набору видов сигнала), живут в `SignalWeights`, а не здесь.
//
//  Разведение сделано не ради красоты: без него утверждение «набор ключей `weights` дословно
//  равен набору сырых значений `MeetingSignalKind`» проверялось бы на значении, которое
//  иначе и не собирается, то есть было бы зелёным по построению.
//
//  Ключи `weights` читаются динамическим `CodingKey`: перечисление здесь дало бы второй
//  источник истины для набора видов сигнала, который объявлен `MeetingSignalKind` (§1).

import Foundation

/// Таблица весов сигналов (§5). Формат файла `signal-weights.json`, дословно.
public struct SignalWeightsTable: Decodable, Equatable, Sendable {

    /// Версия схемы файла, которую принимает этот код.
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    /// Срок актуальности сигнала в секундах (§1).
    public let signalTtlSeconds: Int
    /// Веса, как они стоят в файле: ключ — сырое значение вида сигнала.
    public let weights: [String: Double]

    public init(schemaVersion: Int = SignalWeightsTable.currentSchemaVersion,
                signalTtlSeconds: Int, weights: [String: Double]) {
        self.schemaVersion = schemaVersion
        self.signalTtlSeconds = signalTtlSeconds
        self.weights = weights
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, signalTtlSeconds, weights
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decodeBounded(Int.self, forKey: .schemaVersion)
        try RuleTableSchema.require(schemaVersion, SignalWeightsTable.currentSchemaVersion,
                                    in: box, forKey: .schemaVersion)
        signalTtlSeconds = try box.decodeBounded(Int.self, forKey: .signalTtlSeconds)
        let table = try box.nestedContainer(keyedBy: WeightKey.self, forKey: .weights)
        var read: [String: Double] = [:]
        for key in table.allKeys {
            read[key.stringValue] = try table.decodeFinite(Double.self, forKey: key)
        }
        weights = read
    }
}

/// Ключ объекта `weights`: любая строка. Набор допустимых имён задаёт `MeetingSignalKind`,
/// и проверяется он в `SignalWeights`, а не разбором.
struct WeightKey: CodingKey {

    let stringValue: String

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    var intValue: Int? { nil }

    init?(intValue: Int) { return nil }
}
