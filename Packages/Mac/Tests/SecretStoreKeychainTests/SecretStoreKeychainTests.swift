//
//  SecretStoreKeychainTests — тесты SecretStoreKeychain на настоящем временном Keychain.
//
//  Модуль: secret-store-keychain · Владелец: DEV-1
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
//  ОШИБКИ (IR-125, MEE-368; возврат РП, MEE-364): `get` на отсутствующей записи — `nil`,
//  не отказ. `set(value: nil)` на отсутствующей записи — успех без действия, не отказ
//  (идемпотентное удаление). Обязательный вектор на оба случая — предмет этих тестов.
//  `SecretStoreKeychainError.denied(status:)` — покрыт: `SecKeychainLock` на СВОЙ временный
//  keychain теста + `SecKeychainSetUserInteractionAllowed(false)` (без диалога системы) даёт
//  детерминированный `errSecAuthFailed` (`test_ss12_deniedOnLockedTempKeychain`).
//
//  Что остаётся ручной проверкой (решение РП): заблокированный LOGIN keychain (первый
//  диалог разблокировки подписанного установленного приложения) и отклонённый доступ
//  СТОРОННЕГО приложения к чужой записи — обе ветви `.denied` требуют интерактивной сессии
//  за пределами CI, не воспроизводятся временным keychain теста. Решение — IR-122/IR-125,
//  MEE-358/MEE-368.
//
//  `SecretStoreKeychainError.unexpected(status:)` — НЕ покрыт автоматически. Единственный
//  опробованный вектор (удалённый/недействительный keychain → `errSecNoSuchKeychain`) на
//  macos-14 CI не отказывает: `SecItemCopyMatching`/`SecItemAdd` через такую ссылку молча
//  проходят (три независимых захода, история — комментарий в MEE-364). Посылка К12/К13(ii)
//  перечня MEE-366 эмпирически не подтвердилась — находка передана аналитику.
//

import CalendarHub
import Foundation
import Security
import XCTest
@testable import SecretStoreKeychain

final class SecretStoreKeychainTests: XCTestCase {

    private var keychain: SecKeychain?
    private var keychainURL: URL!
    private var store: SecretStoreKeychain!
    private var searchListBeforeSetUp: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // К10: снимок ДО создания временного keychain — общий пролог для всех тестов,
        // сравнение делает только test_ss10 сама.
        searchListBeforeSetUp = Self.currentSearchListPaths()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecretStoreKeychainTests-\(UUID().uuidString).keychain")
        keychainURL = url
        let password = "test-password"
        var ref: SecKeychain?
        let status = password.withCString { passwordPtr in
            url.path.withCString { pathPtr in
                SecKeychainCreate(pathPtr, UInt32(password.utf8.count), passwordPtr, false, nil, &ref)
            }
        }
        guard status == errSecSuccess else {
            XCTFail("не удалось создать временный keychain теста: \(status)")
            throw SecretStoreKeychainError(status: status)
        }
        keychain = ref
        store = SecretStoreKeychain(keychain: keychain)
    }

    override func tearDown() {
        // К12/К10 сами удаляют keychain раньше срока и обнуляют `keychain` — повторное
        // удаление здесь не нужно и не должно считаться отказом теста.
        if let keychain {
            SecKeychainDelete(keychain)
        }
        try? FileManager.default.removeItem(at: keychainURL)
        keychain = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Оснастка

    private static func currentSearchListPaths() -> [String] {
        var searchList: CFArray?
        guard SecKeychainCopySearchList(&searchList) == errSecSuccess,
              let list = searchList as? [SecKeychain] else { return [] }
        return list.compactMap(keychainPath)
    }

    private static func keychainPath(_ keychain: SecKeychain) -> String? {
        var length = UInt32(4096)
        var buffer = [Int8](repeating: 0, count: Int(length))
        guard SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess else { return nil }
        return String(cString: buffer)
    }

    /// Явная адресация на временный keychain теста (тестовый шов, IR-125) — прямые проверки
    /// мимо `SecretStore` обязаны искать здесь же, не в списке поиска процесса.
    private var searchList: [SecKeychain] {
        get throws { [try XCTUnwrap(keychain)] }
    }

    private func itemCount(key: String, namespace: String) throws -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "meet-for-me.calendar-hub.\(namespace)",
            kSecAttrAccount as String: key,
            kSecMatchSearchList as String: try searchList,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return 0 }
        XCTAssertEqual(status, errSecSuccess)
        return (result as? [Any])?.count ?? 1
    }

    // MARK: - А. Базовые операции (C-006 §4, инв. 11) — К1-К4

    func test_ss01_roundTripSetThenGet() async throws {
        try await store.set(key: "refreshToken", value: "tok-abc", namespace: "eventkit-1")
        let value = try await store.get(key: "refreshToken", namespace: "eventkit-1")
        XCTAssertEqual(value, "tok-abc")
    }

    func test_ss02_setNilDeletesRecord() async throws {
        try await store.set(key: "refreshToken", value: "tok-abc", namespace: "eventkit-1")
        try await store.set(key: "refreshToken", value: nil, namespace: "eventkit-1")
        let value = try await store.get(key: "refreshToken", namespace: "eventkit-1")
        XCTAssertNil(value)
    }

    func test_ss03_missingKeyReturnsNilNotThrows() async throws {
        let value = try await store.get(key: "never-set", namespace: "eventkit-1")
        XCTAssertNil(value)
    }

    func test_ss04_repeatedSetOverwritesNotDuplicates() async throws {
        try await store.set(key: "refreshToken", value: "v1", namespace: "eventkit-1")
        try await store.set(key: "refreshToken", value: "v2", namespace: "eventkit-1")
        let value = try await store.get(key: "refreshToken", namespace: "eventkit-1")
        XCTAssertEqual(value, "v2")
        let count = try itemCount(key: "refreshToken", namespace: "eventkit-1")
        XCTAssertEqual(count, 1, "ровно одна запись на пару ключ/namespace — SecItemUpdate, не второй SecItemAdd")
    }

    // MARK: - Б. Раскладка Keychain — К5-К7

    func test_ss05_attributeLayoutMatchesIR122() async throws {
        try await store.set(key: "refreshToken", value: "tok", namespace: "eventkit-1")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "meet-for-me.calendar-hub.eventkit-1",
            kSecAttrAccount as String: "refreshToken",
            kSecMatchSearchList as String: try searchList,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attrs = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attrs[kSecAttrService as String] as? String, "meet-for-me.calendar-hub.eventkit-1")
        XCTAssertEqual(attrs[kSecAttrAccount as String] as? String, "refreshToken")
    }

    func test_ss06_findableViaLegacyFileBasedAPI() async throws {
        try await store.set(key: "refreshToken", value: "tok", namespace: "eventkit-1")

        let service = "meet-for-me.calendar-hub.eventkit-1"
        let account = "refreshToken"
        var itemRef: SecKeychainItem?
        let status = SecKeychainFindGenericPassword(
            keychain, UInt32(service.utf8.count), service, UInt32(account.utf8.count), account, nil, nil, &itemRef
        )
        XCTAssertEqual(status, errSecSuccess, "SecKeychain* находит запись только в файловом keychain")
    }

    func test_ss07_notSynchronizable() async throws {
        try await store.set(key: "refreshToken", value: "tok", namespace: "eventkit-1")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "meet-for-me.calendar-hub.eventkit-1",
            kSecAttrAccount as String: "refreshToken",
            kSecMatchSearchList as String: try searchList,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attrs = try XCTUnwrap(result as? [String: Any])
        let synchronizable = attrs[kSecAttrSynchronizable as String] as? Bool ?? false
        XCTAssertFalse(synchronizable)
    }

    // MARK: - В. Изоляция и раздельные атрибуты (C-006 инв. 12) — К8-К9

    func test_ss08_namespaceIsolation() async throws {
        try await store.set(key: "refreshToken", value: "tok-1", namespace: "eventkit-1")
        try await store.set(key: "refreshToken", value: "tok-2", namespace: "graph-work-1")

        let value1 = try await store.get(key: "refreshToken", namespace: "eventkit-1")
        let value2 = try await store.get(key: "refreshToken", namespace: "graph-work-1")
        XCTAssertEqual(value1, "tok-1")
        XCTAssertEqual(value2, "tok-2")

        try await store.set(key: "refreshToken", value: nil, namespace: "eventkit-1")
        let stillValue2 = try await store.get(key: "refreshToken", namespace: "graph-work-1")
        XCTAssertEqual(stillValue2, "tok-2", "удаление одного namespace не трогает другой")
    }

    func test_ss09_noDelimiterCollision() async throws {
        try await store.set(key: "y/z", value: "a", namespace: "x")
        try await store.set(key: "z", value: "b", namespace: "x/y")

        let valueA = try await store.get(key: "y/z", namespace: "x")
        let valueB = try await store.get(key: "z", namespace: "x/y")
        XCTAssertEqual(valueA, "a")
        XCTAssertEqual(valueB, "b")
    }

    // MARK: - Г. Список поиска процесса не меняется — К10

    func test_ss10_processSearchListUnchanged() throws {
        let doomedKeychain = try XCTUnwrap(keychain)
        XCTAssertEqual(SecKeychainDelete(doomedKeychain), errSecSuccess)
        keychain = nil // общий tearDown не должен удалять его повторно

        let after = Self.currentSearchListPaths()
        XCTAssertEqual(after, searchListBeforeSetUp, "список поиска процесса не должен меняться за время теста")
    }

    // MARK: - Е. Ошибки Keychain — К12-К14

    /// Возврат РП (CI, macos-14): ТРИ попытки получить `.unexpected(status: errSecNoSuchKeychain)`
    /// с недействительного/удалённого keychain (`SecKeychainDelete` + повторное использование
    /// ссылки; `SecKeychainOpen` на никогда не существовавшем пути; 0o444 на файл под доказанно
    /// рабочей ссылкой) на macos-14 CI не отказали ни разу. Диагноз РП: `SecItemCopyMatching` по
    /// недоступному в списке поиска keychain отдаёт `errSecItemNotFound` — реализация честно
    /// трактует это как «нет записи» и уходит в `SecItemAdd`, который на этой платформе тоже не
    /// отказывает через такую ссылку. Посылка К12/К13(ii) перечня MEE-366 (`errSecNoSuchKeychain`
    /// от удалённого keychain) эмпирически не подтверждается на macos-14 CI — находка для отчёта
    /// в MEE-364, не решаемая этим тестом в одиночку. Выделенного шва для подстановки
    /// произвольного `OSStatus` в модуле нет (MEE-380 §1 — способ «Т» только через настоящий
    /// Keychain Services, второй способ — «мех./компиляция», не подстановка).
    ///
    /// Вместо неё — детерминированный вектор `.denied`, который перечень раньше относил только
    /// к РУЧНОЙ проверке: `SecKeychainLock` на СВОЙ временный keychain теста (не login) +
    /// `SecKeychainSetUserInteractionAllowed(false)` (глобально для процесса, восстанавливается
    /// `defer` до конца этого метода — файл гоняется строго последовательно, CI без
    /// `--parallel`, гонки с соседним тестом нет) — без диалога системы, детерминированно даёт
    /// `.denied`. Возврат РП, MEE-364: конкретный `OSStatus` внутри `.denied` не фиксируем —
    /// на CI это `errSecAuthFailed`, но контракт объявляет оба случая (`errSecAuthFailed`/
    /// `errSecInteractionNotAllowed`) равноправно, пиновать один из двух ничем не оправдано.
    /// Собственный вектор К12/К13(ii) (`errSecNoSuchKeychain`/`.unexpected`) остаётся
    /// неавтоматизированным — см. отчёт в MEE-364.
    func test_ss12_deniedOnLockedTempKeychain() async throws {
        let keychainToLock = try XCTUnwrap(keychain)
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(false), errSecSuccess)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        XCTAssertEqual(SecKeychainLock(keychainToLock), errSecSuccess)
        defer {
            let password = "test-password"
            _ = password.withCString { SecKeychainUnlock(keychainToLock, UInt32(password.utf8.count), $0, true) }
        }

        do {
            try await store.set(key: "refreshToken", value: "tok", namespace: "eventkit-1")
            XCTFail("ожидалась ошибка — keychain заперт, взаимодействие с пользователем выключено")
        } catch let error as SecretStoreKeychainError {
            switch error {
            case .denied:
                break // конкретный OSStatus не фиксируем — errSecAuthFailed/errSecInteractionNotAllowed равноправны
            case .unexpected:
                XCTFail("ожидался .denied, получен .unexpected")
            }
        }
    }

    /// К13(i) — мех./компиляция: исчерпывающий `switch` без `default` компилируется только
    /// при ровно двух `case`ах `SecretStoreKeychainError`; появление/исчезновение третьего
    /// ломает сборку этой цели, не прогон.
    func test_ss13_errorTypeIsExhaustiveTwoCases() {
        let sample = SecretStoreKeychainError.unexpected(status: errSecItemNotFound)
        switch sample {
        case .denied: break
        case .unexpected: break
        }
    }

    func test_ss14_setNilOnNeverSetPairSucceeds() async throws {
        try await store.set(key: "never-set-2", value: nil, namespace: "eventkit-1")
    }
}
