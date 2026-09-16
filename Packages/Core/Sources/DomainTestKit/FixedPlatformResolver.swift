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
//  Разбор события (`resolve(event:)`) фейк ведёт в порядке инварианта 3 C-009 и спрашивает
//  о каждом поле СВОЙ ЖЕ словарь. Исключения инварианта 4 (`provider == "unknown"` на
//  структурном поле `conference`) у него нет, и это решение, а не недосмотр: п. 149 перечня
//  MEE-6 требует вектор «текста нет в словаре → `nil`», а автоматический `unknown` завёл бы
//  у фейка второй источник ответа помимо теста. Тесту, которому нужна эта ветвь, ответ на
//  неё кладётся в словарь — ровно так же, как всякий другой.

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

    public func resolve(event: MeetingEvent) -> JoinInfo? {
        for field in FixedPlatformResolver.orderedFields(of: event) {
            if let answer = resolve(text: field.text, source: field.source) {
                return answer
            }
        }
        return nil
    }

    public func resolve(text: String, source: JoinInfo.Source) -> JoinInfo? {
        answers[text]
    }

    /// Поля события в порядке инварианта 3 C-009: `conference` → `location` → `eventUrl` →
    /// `bodyText`. Стадия `eventUrl` входа не имеет — поля URL события C-001 v11 не
    /// объявляет; остальные три идут в контрактном порядке.
    private static func orderedFields(of event: MeetingEvent) -> [(text: String, source: JoinInfo.Source)] {
        var ordered: [(text: String, source: JoinInfo.Source)] = []
        if let conference = event.conference {
            ordered.append((conference.joinUrl.absoluteString, .conferenceField))
        }
        if let location = event.location {
            ordered.append((location, .location))
        }
        if let bodyText = event.bodyText {
            ordered.append((bodyText, .bodyText))
        }
        return ordered
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
