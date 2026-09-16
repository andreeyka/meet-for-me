//  LinkResolver — разбор текста в `JoinInfo` по правилам `providers.json` (C-009 §2, §3).
//
//  Инварианты 2, 5, 6, 7: разбор детерминирован, в сеть не ходит и не читает ничего, кроме
//  переданного текста и таблиц; `joinUrl` — абсолютный `https`-URL; `provider` — ключ из
//  таблицы; `clientBundleIds` — из таблицы клиентов.
//
//  Порядок проверки — по правилам, а не по ссылкам в тексте: правила перебираются по
//  возрастанию `priority` (при равенстве — в порядке файла), и для каждого правила — ссылки
//  текста в порядке появления. Первое совпадение побеждает (§3).
//
//  Ссылка без совпавшего правила даёт `nil` при любом `source`. Исключение инварианта 4
//  (`provider == "unknown"` для структурного поля `conference`) принадлежит разбору СОБЫТИЯ:
//  оно говорит «ни одно правило не совпало ни в одном поле», а у текста полей нет. Разбор
//  события — `resolve(event:tables:)` ниже, инварианты 3 и 4 (MEE-220).

import DomainCore
import Foundation

enum LinkResolver {

    /// Значение `provider`, которым инвариант 4 велит отвечать на структурном поле `conference`,
    /// не совпавшем ни с одним правилом. Ключом таблицы оно не бывает — инвариант 6 добавляет
    /// его к множеству ключей отдельно.
    static let unknownProvider = "unknown"

    // MARK: - Разбор события (инварианты 3 и 4)

    /// Порядок разбора строгий: `conference` → `location` → `bodyText`; первое поле, давшее
    /// совпадение, побеждает, и `JoinInfo.source` равен этому полю (инвариант 3).
    ///
    /// Стадий ровно три, потому что три и поля `MeetingEvent`, из которых контракт берёт
    /// ссылку: это равенство сам инвариант 3 называет правилом, а не совпадением. Четвёртой
    /// стадии, объявляющей себя полем URL события, у порядка нет — как нет у `JoinInfo.Source`
    /// и случая под неё.
    ///
    /// Исключение инварианта 4 проверяется ПОСЛЕ обхода всех полей: оно обусловлено тем, что
    /// не совпало ни одно правило **ни в одном** поле, а не тем, что не совпало `conference`.
    static func resolve(event: MeetingEvent, tables: RuleTables) -> JoinInfo? {
        for field in fields(of: event) {
            if let info = resolve(text: field.text, source: field.source, tables: tables) {
                return info
            }
        }
        guard let conference = event.conference, isAbsoluteHTTPS(conference.joinUrl) else {
            return nil
        }
        return JoinInfo(provider: unknownProvider, joinUrl: conference.joinUrl, meetingId: nil,
                        passcode: nil, clientBundleIds: [], source: .conferenceField)
    }

    /// Поля события в порядке инварианта 3. `nil`-поле стадии не даёт: разбирать нечего.
    private static func fields(of event: MeetingEvent) -> [(text: String, source: JoinInfo.Source)] {
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

    /// Условие исключения инварианта 4 дословно: абсолютный URL со схемой `https`.
    ///
    /// На событии, собранном по C-001, ложным оно сегодня не бывает — тот же признак стоит
    /// инвариантом 5 C-001 и проверяется при создании `MeetingEvent.Conference`. Проверка
    /// стоит здесь потому, что инвариант 4 требует её от НАС: связь двух контрактов держится
    /// текстом C-001, а не нашим кодом, и ослабнет она молча.
    private static func isAbsoluteHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
    }

    // MARK: - Разбор текста

    static func resolve(text: String, source: JoinInfo.Source, tables: RuleTables) -> JoinInfo? {
        let candidates = httpsLinks(in: text)
        guard !candidates.isEmpty else { return nil }
        for rule in tables.linkRules {
            for link in candidates {
                if let info = match(link, rule: rule, source: source, tables: tables) {
                    return info
                }
            }
        }
        return nil
    }

    // MARK: - Ссылки в тексте

    private static let linkPattern: NSRegularExpression? =
        try? NSRegularExpression(pattern: "https://[^\\s<>\"'`()\\[\\]{}]+", options: [.caseInsensitive])

    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// Абсолютные `https`-ссылки текста в порядке появления.
    static func httpsLinks(in text: String) -> [URLComponents] {
        guard let pattern = linkPattern else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: whole).compactMap { found in
            guard let span = Range(found.range, in: text) else { return nil }
            var raw = String(text[span])
            while let last = raw.last, trailingPunctuation.contains(last) {
                raw.removeLast()
            }
            guard let parts = URLComponents(string: raw),
                  parts.scheme?.lowercased() == "https",
                  let host = parts.host, !host.isEmpty,
                  parts.url?.absoluteURL != nil else { return nil }
            return parts
        }
    }

    // MARK: - Одно правило на одну ссылку

    private static func match(_ link: URLComponents, rule: LinkRule, source: JoinInfo.Source,
                              tables: RuleTables) -> JoinInfo? {
        guard let host = link.host?.lowercased(), hostMatches(host, suffix: rule.hostSuffix),
              let url = link.url else { return nil }
        let path = link.path
        let whole = NSRange(path.startIndex..., in: path)
        guard let found = rule.pathRegex.firstMatch(in: path, range: whole) else { return nil }
        let meetingId = group("meetingId", present: rule.hasMeetingIdGroup, in: found, of: path)
            ?? query(rule.meetingIdQueryKey, in: link)
        let passcode = group("passcode", present: rule.hasPasscodeGroup, in: found, of: path)
            ?? query(rule.passcodeQueryKey, in: link)
        return JoinInfo(provider: rule.provider,
                        joinUrl: url,
                        meetingId: meetingId,
                        passcode: passcode,
                        clientBundleIds: tables.clientBundleIds(for: rule.provider),
                        source: source)
    }

    /// §3: хост в нижнем регистре равен `hostSuffix` или кончается на `"." + hostSuffix`.
    static func hostMatches(_ host: String, suffix: String) -> Bool {
        host == suffix || host.hasSuffix("." + suffix)
    }

    private static func group(_ name: String, present: Bool, in found: NSTextCheckingResult,
                              of path: String) -> String? {
        guard present, let span = Range(found.range(withName: name), in: path) else { return nil }
        let value = String(path[span])
        return value.isEmpty ? nil : value
    }

    private static func query(_ key: String?, in link: URLComponents) -> String? {
        guard let key, let value = link.queryItems?.first(where: { $0.name == key })?.value,
              !value.isEmpty else { return nil }
        return value
    }
}
