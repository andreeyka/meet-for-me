//  DetectorResources — единственное место модуля, где читаются файлы-ресурсы.
//
//  C-009 §6 и инвариант 23: таблицы `providers.json` и `clients.json` — ресурсы собранного
//  модуля `detector`, путь чтения один, внешнего файла и отката нет. Шов Ш2 (i): байты
//  приходят отсюда и ниоткуда больше; построение правил из них — чистая функция
//  `RuleTables.build`, вызываемая тестом напрямую.
//
//  Таблицу весов модуль не читает: её значения приходят в публичный инициализатор
//  `MeetingDetector` от `domain-core` (§6, шов Ш5).

import Foundation

enum DetectorResources {

    /// Имя файла-ресурса таблицы правил без расширения.
    enum Table: String, CaseIterable {
        case providers
        case clients
    }

    /// Адрес ресурса в собранном модуле: его задаёт сборка, а не модуль.
    static func location(of table: Table) -> URL? {
        Bundle.module.url(forResource: table.rawValue, withExtension: "json")
    }

    /// Байты таблицы, как их положила сборка модуля.
    static func bytes(of table: Table) throws -> Data {
        guard let url = location(of: table) else {
            throw RuleTableError.resourceMissing(table.rawValue)
        }
        return try Data(contentsOf: url)
    }
}
