//  RuleTableSchema — общая проверка поля версии у трёх таблиц правил C-009.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  §«Поведение» C-009 называет «отсутствующая или неизвестная `schemaVersion`» первым случаем,
//  в котором таблицу нельзя прочитать; отсутствие ловит сам `decodeBounded` (`keyNotFound`),
//  неизвестность — эта проверка. Отказ выражен `DecodingError.dataCorrupted` с именем ключа
//  в `codingPath`: у C-009 нет ни одного `DomainValidatable`-типа, и `DomainValidationError`
//  (C-001 §0.1) здесь бросить нечем — его `contract` объявлен для C-001…C-003.
//
//  Место общее у трёх таблиц намеренно: правило одно, и три его копии разошлись бы молча.
//  Тип не публичный: наружу модуля выходит отказ, а не способ его поставить (П2).

import Foundation

enum RuleTableSchema {

    /// Отказ, если прочитанная версия схемы не та, которую принимает код таблицы.
    static func require<Key: CodingKey>(
        _ actual: Int,
        _ expected: Int,
        in box: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws {
        guard actual == expected else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: box.codingPath + [key],
                debugDescription: "неизвестная schemaVersion \(actual); принимается \(expected)"))
        }
    }
}
