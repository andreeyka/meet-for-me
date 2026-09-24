//
//  SecretStoreKeychainTests — каркас без кода.
//
//  Реальные round-trip-тесты идут против временного файлового тестового Keychain —
//  Keychain Services не требуют TCC-разрешения для операций над собственным keychain
//  процесса, в отличие от `permissions`.
//
//  ШОВ (IR-125, MEE-368): создать/разблокировать временный keychain-файл, передать его
//  в `SecretStoreKeychain` через `internal init(keychain:)` (`@testable import
//  SecretStoreKeychain`) — НЕ через `SecKeychainSetSearchList`. Список поиска процесса
//  решает, где Keychain Services ИЩЕТ (`SecItemCopyMatching`), а не куда ПИШЕТ
//  (`SecItemAdd` без `kSecUseKeychain` пишет в keychain по умолчанию независимо от
//  списка поиска) — округление списка поиска не направило бы запись во временный файл, и
//  тест писал бы в login keychain разработчика/раннера CI. Ни `setUp`/`tearDown` не трогает
//  глобальный список поиска процесса вовсе — нет глобального состояния, нет необходимости
//  его восстанавливать, нет риска гонки между параллельными тестами. `tearDown` удаляет
//  только сам временный keychain-файл.
//
//  Обязательный вектор: namespace="x", key="y/z" и namespace="x/y", key="z" — оба должны
//  дать РАЗНЫЕ записи (раздельные kSecAttrService/kSecAttrAccount, не конкатенация).
//
//  ОШИБКИ (IR-125, MEE-368; малый возврат): `get` на отсутствующей записи — `nil`, не отказ.
//  `set(value: nil)` на отсутствующей записи — успех без действия, не отказ (идемпотентное
//  удаление). Обязательный вектор на оба случая — предмет этих тестов, не только ручной
//  проверки. `SecretStoreKeychainError.unexpected(status:)` — вектор на любой другой
//  не-`errSecItemNotFound` отказ Keychain Services, тоже предмет этих тестов (например,
//  через подмену запроса на заведомо негодный).
//
//  Что остаётся ручной проверкой (решение РП, малый возврат): `SecretStoreKeychainError
//  .denied(status:)` — заблокированный login keychain (`errSecInteractionNotAllowed`) и
//  отклонённый доступ (`errSecAuthFailed`) — и первый диалог доступа подписанного,
//  установленного приложения. Автоматический вектор потребовал бы `SecKeychainLock` и
//  `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail` — без второго тест на машине
//  разработчика повиснет на диалоге системы, цена без выгоды для Среза 1. Решение —
//  IR-122/IR-125, MEE-358/MEE-368.
//
