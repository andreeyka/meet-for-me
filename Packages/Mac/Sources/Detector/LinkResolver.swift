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
//  оно говорит «ни одно правило не совпало ни в одном поле», а у текста полей нет. Метод
//  `resolve(event:)` в протоколе не объявлен (MEE-220) и в этой задаче не пишется.

import DomainCore
import Foundation

enum LinkResolver {

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
