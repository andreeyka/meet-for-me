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
//  ОШИБКИ (IR-125, MEE-368): собственный `enum` этого модуля (внутренний, не публичный —
//  `SecretStore.get`/`set` объявлены `async throws` без типа ошибки, конкретный тип
//  публичным быть не обязан) — НЕ `ConnectorError` (C-006 §6: тот для ошибки ПЛАГИНА,
//  обратное направление) и не тип `DomainCore`. Два случая: заблокированный/отклонённый
//  доступ (`errSecInteractionNotAllowed`, `errSecAuthFailed` — диалог показать некому в
//  headless/CI) и любой другой `OSStatus` — «неожиданный». `get(key:namespace:)` на
//  `errSecItemNotFound` отдаёт `nil`, не бросает — это ответ по типу метода (`String?`), а
//  не отказ. `set(key:value: nil, namespace:)` на отсутствующей записи — успех без
//  действия: `errSecItemNotFound` от `SecItemDelete` не пробрасывается, удаление уже
//  отсутствующего идемпотентно (тот же довод, что уже принят для
//  `ConnectorHostServices.secretSet`, MEE-346, PR #71).
//
