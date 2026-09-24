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
