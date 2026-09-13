//  FixedPlatformResolver — реализация `PlatformResolver` поверх заданного тестом словаря,
//  C-009 §«Фейк для тестов», абзац второй.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Довод, ради которого фейк существует, назван контрактом: `calendar-hub` обязан тестировать
//  нормализацию событий, «не подключая настоящие таблицы модуля `detector`, который живёт в
//  другом пакете и на Linux не собирается».
//
//  Отсюда прямо: ни одной таблицы этот тип не читает. Ни `providers.json`, ни `clients.json`,
//  ни ресурсов — ответы целиком задаёт тест. Список браузеров — тоже вход теста, а не таблица:
//  он нужен, чтобы `isBrowser(appKey:)` отвечал не одной константой.
//
//  Правило сравнения берётся у домена — `bundleKeyMatches` (§4.1), а не своё: двух мнений
//  о том, что совпало, не заводится даже у фейка.
//
//  Протокол `PlatformResolver` объявлен в дереве неполно и сознательно (см. его заголовок);
//  фейк реализует его целиком таким, каков он на сегодня.

import Foundation
import DomainCore

/// Фейк резолвера площадок: «текст → `JoinInfo`» по словарю теста.
public struct FixedPlatformResolver: PlatformResolver, Sendable {

    private let answers: [String: JoinInfo]
    private let browsers: [String]

    /// - Parameters:
    ///   - answers: тексты и ответы на них; текста нет в словаре — ответ `nil`.
    ///   - browsers: bundle id приложений-браузеров, которыми тест хочет наделить фейк.
    public init(answers: [String: JoinInfo], browsers: [String] = []) {
        self.answers = answers
        self.browsers = browsers
    }

    public func resolve(text: String, source: JoinInfo.Source) -> JoinInfo? {
        answers[text]
    }

    public func clientBundleIds(for provider: String) -> [String] {
        answers.values
            .filter { $0.provider == provider }
            .flatMap(\.clientBundleIds)
            .uniqueInOrder()
    }

    public func allKnownClientBundleIds() -> [String] {
        answers.values.flatMap(\.clientBundleIds).uniqueInOrder()
    }

    public func provider(forAppKey appKey: String) -> String? {
        answers.values
            .sorted { $0.provider < $1.provider }
            .first { info in
                info.clientBundleIds.contains { bundleKeyMatches(appKey: appKey, entry: $0) }
            }?
            .provider
    }

    public func isBrowser(appKey: String) -> Bool {
        browsers.contains { bundleKeyMatches(appKey: appKey, entry: $0) }
    }
}

private extension Array where Element == String {

    /// Без повторов и с устойчивым порядком: словарь неупорядочен, а ответ обязан быть один
    /// и тот же на всех прогонах.
    func uniqueInOrder() -> [String] {
        var seen: Set<String> = []
        return sorted().filter { seen.insert($0).inserted }
    }
}
