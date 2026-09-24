//
//  SecretStoreKeychain — SecretStore на файловом Keychain (IR-122/IR-125, MEE-364).
//
//  Модуль: secret-store-keychain · Владелец: DEV-1
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
//      `errSecAuthFailed` (keychain заблокирован или доступ отклонён). Возврат РП, MEE-364:
//      покрыт CI-вектором — `SecKeychainLock` на СВОЙ временный keychain теста +
//      `SecKeychainSetUserInteractionAllowed(false)` (без диалога системы, без риска подвесить
//      тест на машине разработчика) — `SecretStoreKeychainTests.test_ss12_deniedOnLockedTempKeychain`.
//    * `SecretStoreKeychainError.unexpected(status: OSStatus)` — любой другой не-`errSecSuccess`
//      код, несёт его `OSStatus` дословно. Конкретный автоматический вектор (удалённый/
//      недействительный keychain → `errSecNoSuchKeychain`) НЕ покрыт: на macos-14 CI такая
//      ссылка не отказывает ни на `SecItemCopyMatching`, ни на `SecItemAdd` — находка передана
//      аналитику (MEE-366/MEE-364), посылка К12/К13(ii) перечня эмпирически не подтвердилась.
//  `get(key:namespace:)` на `errSecItemNotFound` отдаёт `nil`, не бросает — это ответ по типу
//  метода (`String?`), а не отказ. `set(key:value: nil, namespace:)` на отсутствующей записи —
//  успех без действия: `errSecItemNotFound` от `SecItemDelete` не пробрасывается, удаление уже
//  отсутствующего идемпотентно (тот же довод, что уже принят для
//  `ConnectorHostServices.secretSet`, MEE-346, PR #71).
//  По проводу (`host/secrets.*`, C-006 §4/v14): отказ → JSON-RPC `-32603 internal error`,
//  `message` — `SecCopyErrorMessageString(status, nil)` (системное описание `OSStatus`), а без
//  него — сам числовой `OSStatus`.
//

import CalendarHub
import Foundation
import Security

public struct SecretStoreKeychain: SecretStore {

    private let keychain: SecKeychain?

    public init() {
        self.init(keychain: nil)
    }

    init(keychain: SecKeychain?) {
        self.keychain = keychain
    }

    public func get(key: String, namespace: String) async throws -> String? {
        var query = searchQuery(key: key, namespace: namespace)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreKeychainError(status: status)
        }
        return value
    }

    public func set(key: String, value: String?, namespace: String) async throws {
        guard let value else {
            let status = SecItemDelete(searchQuery(key: key, namespace: namespace) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreKeychainError(status: status)
            }
            return
        }
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            searchQuery(key: key, namespace: namespace) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(addQuery(key: key, namespace: namespace, data: data) as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreKeychainError(status: addStatus)
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw SecretStoreKeychainError(status: updateStatus)
        }
    }

    private func baseAttributes(key: String, namespace: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "meet-for-me.calendar-hub.\(namespace)",
            kSecAttrAccount as String: key
        ]
    }

    /// Поиск (`SecItemCopyMatching`/`SecItemUpdate`/`SecItemDelete`) — список поиска
    /// сужается явно на переданный keychain (тестовый шов, IR-125): без этого поиск шёл бы
    /// по списку поиска процесса, где временного keychain теста нет.
    private func searchQuery(key: String, namespace: String) -> [String: Any] {
        var query = baseAttributes(key: key, namespace: namespace)
        if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    /// Запись (`SecItemAdd`) — куда ПИШЕТ решает `kSecUseKeychain`, не список поиска
    /// (`SecItemAdd` без него пишет в keychain по умолчанию независимо от списка поиска,
    /// находка самой постановки IR-125).
    private func addQuery(key: String, namespace: String, data: Data) -> [String: Any] {
        var query = baseAttributes(key: key, namespace: namespace)
        query[kSecValueData as String] = data
        if let keychain {
            query[kSecUseKeychain as String] = keychain
        }
        return query
    }
}

enum SecretStoreKeychainError: Error, Sendable {
    case denied(status: OSStatus)
    case unexpected(status: OSStatus)

    init(status: OSStatus) {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed:
            self = .denied(status: status)
        default:
            self = .unexpected(status: status)
        }
    }
}
