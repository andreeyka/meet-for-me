//  Эталонные тексты трёх таблиц правил C-009 — п. 146 перечня.
//
//  Написаны вручную, а не получены из кодировщика проекта: вывод `DomainJSON` компактен
//  и с сортированными ключами, а здесь и отступы, и произвольный порядок ключей. Это
//  одновременно доказывает ручное написание и проверяет терпимое чтение, которого §0.4
//  требует прямо.
//
//  Форма — строковые литералы, а не файлы в `Fixtures/`, и опора у формы та же, что у п. 14:
//  каталог `Fixtures/` принадлежит архитектору (`Packages/Core/Package.swift:43`, решение по
//  IR-003), и тестовый таргет править его не вправе. Пункт 146 называет эту форму сам.
//
//  Повторяющихся ключей здесь нет ни на одном уровне; все целые записаны десятичной записью
//  без экспоненты и дробной части и лежат в ±(2^53 − 1).
//
//  Значения — дословно из §3, §4 и §5 контракта. Порядок ключей от контракта отличается
//  намеренно: побайтового совпадения с выводом кодировщика быть не должно.

import Foundation

enum ReferenceTables {

    /// `providers.json` схемы 1 — §3 контракта.
    static let providers = """
    {
      "providers": [
        {
          "priority": 10,
          "provider": "zoom",
          "urlPatterns": [
            {
              "passcodeQueryKey": "pwd",
              "hostSuffix": "zoom.us",
              "meetingIdQueryKey": null,
              "pathRegex": "^/(j|s|w)/(?<meetingId>[0-9]+)"
            }
          ],
          "displayName": "Zoom"
        },
        {
          "provider": "meet",
          "displayName": "Google Meet",
          "urlPatterns": [
            {
              "hostSuffix": "meet.google.com",
              "meetingIdQueryKey": null,
              "passcodeQueryKey": null,
              "pathRegex": "^/(?<meetingId>[a-z]{3}-[a-z]{4}-[a-z]{3})"
            }
          ],
          "priority": 20
        }
      ],
      "schemaVersion": 1
    }
    """

    /// `clients.json` схемы 1 — §4 контракта.
    static let clients = """
    {
      "browsers": [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "ru.yandex.desktop.yandex-browser"
      ],
      "clients": [
        {
          "bundleIds": ["us.zoom.xos"],
          "provider": "zoom",
          "browserFallback": true
        },
        {
          "provider": "teams",
          "browserFallback": true,
          "bundleIds": ["com.microsoft.teams2"]
        },
        {
          "browserFallback": true,
          "provider": "meet",
          "bundleIds": []
        }
      ],
      "schemaVersion": 1
    }
    """

    /// `signal-weights.json` схемы 1 — §5 контракта.
    static let signalWeights = """
    {
      "weights": {
        "clientAudioOutput": 0.8,
        "calendarWindow": 0.2,
        "microphoneInUse": 0.4,
        "clientRunning": 0.4
      },
      "signalTtlSeconds": 60,
      "schemaVersion": 1
    }
    """

    /// Тот же текст с другой версией схемы — вектор отказа (ж) п. 146.
    static func withSchemaVersion(_ version: Int, in text: String) -> String {
        text.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": \(version)")
    }

    /// Тот же текст без ключа версии — вектор отказа (з) п. 146.
    static func withoutSchemaVersion(_ text: String) -> String {
        text
            .replacingOccurrences(of: ",\n  \"schemaVersion\": 1", with: "")
            .replacingOccurrences(of: "\"schemaVersion\": 1,\n  ", with: "")
    }
}
