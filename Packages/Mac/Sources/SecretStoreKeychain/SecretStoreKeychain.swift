//
//  SecretStoreKeychain — каркас без кода.
//
//  Реализует `SecretStore` (протокол объявляет `CalendarHub`, не `DomainCore`) поверх
//  файлового Keychain — `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`/`SecItemDelete`
//  БЕЗ `kSecUseDataProtectionKeychain` (Data Protection keychain недоступен неподписанному
//  тестовому бинарю — `-34018`, нет entitlement `keychain-access-groups`).
//  `kSecClass: kSecClassGenericPassword`; `namespace`/`key` — раздельные атрибуты
//  `kSecAttrService`/`kSecAttrAccount` (не конкатенация — иначе `x`+`y/z` и `x/y`+`z`
//  дали бы одну строку): `kSecAttrService = "meet-for-me.calendar-hub.\(namespace)"`,
//  `kSecAttrAccount = key`. `kSecAttrSynchronizable` не выставляется — без iCloud.
//  Решение и цена — IR-122, MEE-358 (docs/module-map.md, раздел
//  «МОДУЛЬ: secret-store-keychain»). Реализация — задача DEV-1.
//
//  ТЕСТОВЫЙ ШОВ (IR-125, MEE-368): публичный `init()` без параметров делегирует
//  `internal init(keychain: SecKeychain?)` со значением `nil` (keychain по умолчанию,
//  сегодняшнее поведение). Второй инициализатор — `internal`, публичной поверхности не
//  касается (граф символов снимается на публичном уровне доступа); тесты этого же модуля
//  вызывают его через `@testable import SecretStoreKeychain` с временным keychain.
//  НЕПУСТОЙ `keychain` передаётся ЯВНО в каждый вызов Keychain Services — `kSecUseKeychain:
//  keychain` в `SecItemAdd`, `kSecMatchSearchList: [keychain]` в `SecItemCopyMatching`/
//  `SecItemUpdate`/`SecItemDelete`. НЕ через `SecKeychainSetSearchList` (список поиска
//  процесса): список решает, где ИСКАТЬ, а не куда ПИСАТЬ — `SecItemAdd` без
//  `kSecUseKeychain` пишет в keychain по умолчанию независимо от списка поиска, находка
//  самой постановки IR-125.
//
//  ОШИБКИ (IR-125, MEE-368; малый возврат — имена и правка довода): `SecretStoreKeychainError`
//  — собственный `enum` ЭТОГО модуля, `internal`. НЕ тем же приёмом, что сам протокол
//  `SecretStore` — тот ПУБЛИЧНЫЙ (его реализует этот модуль, `calendar-hub` — другой пакет,
//  того и требует реализация чужого протокола). Довод для `internal` свой: единственный
//  вызывающий (`HostServicesImpl.secretGet`/`secretSet`, `calendar-hub`) случаи не различает
//  — пробрасывает брошенное `SecretStore` не читая (PR #85: `try await secretStore.get(...)`
//  без `catch`). НЕ `ConnectorError` (C-006 §6: тот для ошибки ПЛАГИНА, обратное направление)
//  и не тип `DomainCore`. Два случая:
//    * `SecretStoreKeychainError.denied(status: OSStatus)` — `errSecInteractionNotAllowed`/
//      `errSecAuthFailed` (keychain заблокирован или доступ отклонён). Решение РП: проверяется
//      ВРУЧНУЮ, не вектором CI — `SecKeychainLock`/`kSecUseAuthenticationUIFail` подвесили бы
//      тест на диалоге системы на машине разработчика, цена без выгоды для Среза 1.
//    * `SecretStoreKeychainError.unexpected(status: OSStatus)` — любой другой не-`errSecSuccess`
//      код, несёт его `OSStatus` дословно.
//  `get(key:namespace:)` на `errSecItemNotFound` отдаёт `nil`, не бросает — это ответ по типу
//  метода (`String?`), а не отказ. `set(key:value: nil, namespace:)` на отсутствующей записи —
//  успех без действия: `errSecItemNotFound` от `SecItemDelete` не пробрасывается, удаление уже
//  отсутствующего идемпотентно (тот же довод, что уже принят для
//  `ConnectorHostServices.secretSet`, MEE-346, PR #71).
//  По проводу (`host/secrets.*`, C-006 §4/v14): отказ → JSON-RPC `-32603 internal error`,
//  `message` — `SecCopyErrorMessageString(status, nil)` (системное описание `OSStatus`), а без
//  него — сам числовой `OSStatus`.
//
