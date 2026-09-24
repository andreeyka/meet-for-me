//
//  SecretStoreKeychainTests — каркас без кода.
//
//  Реальные round-trip-тесты идут против временного тестового Keychain
//  (create/unlock/add-to-search-list в setUp, delete в tearDown) — Keychain Services
//  не требуют TCC-разрешения для операций над собственным keychain процесса, в отличие
//  от `permissions`. Что остаётся ручной проверкой — entitlement `keychain-access-group`
//  подписанного бандла и синхронизация iCloud Keychain. Решение — IR-122, MEE-358.
//
