//  ModelCatalogManager — хранение пользовательских профилей в `app_settings` (C-014 v7,
//  инв. 37; IR-141 п. 1).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  Одна строка: ключ `modelCatalog.userProfiles`, значение — `DomainJSON.encode` массива всех
//  пользовательских профилей по возрастанию `id` (нет профилей — `[]`). Строки нет — штатный
//  первый запуск, профилей нет. `model-manager` — единственный писатель ключа и держит
//  прочитанное в памяти; пока чтение не удалось, читает заново при каждом обращении.
//
//  Строка есть, а не читается (отказ порта, байты не разбираются, запись с `isBuiltIn == true`)
//  — `userProfilesUnreadable(message:)` у `saveProfile`/`deleteProfile`/`resolve`/`missingModels`,
//  ничего не пишется; `profiles()` отдаёт только встроенные.
//
//  Запись — массив целиком ДО изменения памяти и `profilesChanged`; отказ записи уходит наружу
//  как есть (`StorageError`), память не меняется. Записи идут по одной (`withProfileWriteLock`):
//  актор между `await` принимает другие вызовы, и две параллельные записи иначе затёрли бы
//  одна другую.

import Foundation
import DomainCore

extension ModelCatalogManager {

    /// Ключ строки в `app_settings` (инв. 37). Точка исключает столкновение с полями `AppSettings`.
    static let userProfilesKey = "modelCatalog.userProfiles"

    /// Пользовательские профили по `id`; читает строку, если она ещё не прочитана.
    func loadUserProfiles() async throws -> [String: TranscriptionProfile] {
        if let userProfiles {
            return userProfiles
        }
        let key = Self.userProfilesKey
        let data: Data?
        do {
            data = try await settings.value(forKey: key)
        } catch {
            throw ModelCatalogError.userProfilesUnreadable(message: "\(key): отказ SettingsRepository: \(error)")
        }
        if let userProfiles {
            return userProfiles                    // прочитано параллельным вызовом за время `await`
        }
        guard let data else {
            userProfiles = [:]                     // строки нет — профилей нет
            return [:]
        }
        let list: [TranscriptionProfile]
        do {
            list = try DomainJSON.decode([TranscriptionProfile].self, from: data)
        } catch {
            throw ModelCatalogError.userProfilesUnreadable(message: "\(key): байты не разбираются: \(error)")
        }
        if let builtIn = list.first(where: \.isBuiltIn) {
            throw ModelCatalogError.userProfilesUnreadable(
                message: "\(key): профиль «\(builtIn.id)» с isBuiltIn == true в пользовательских")
        }
        var byId: [String: TranscriptionProfile] = [:]
        for profile in list {
            guard byId[profile.id] == nil else {
                throw ModelCatalogError.userProfilesUnreadable(message: "\(key): профиль «\(profile.id)» повторяется")
            }
            byId[profile.id] = profile
        }
        userProfiles = byId
        return byId
    }

    /// Записывает новый набор пользовательских профилей, затем меняет память и публикует
    /// `profilesChanged`. Отказ записи — наружу как есть, память прежняя.
    func storeUserProfiles(_ profiles: [String: TranscriptionProfile]) async throws {
        let sorted = profiles.values.sorted { $0.id < $1.id }
        let data = try DomainJSON.encode(sorted)
        try await settings.setValue(data, forKey: Self.userProfilesKey)
        userProfiles = profiles
        hub.yield(.profilesChanged)
    }

    /// Изменения профилей по одному: чтение, проверка, запись и смена памяти — без вклинивания
    /// другой записи между `await`.
    func withProfileWriteLock<Value>(_ body: () async throws -> Value) async throws -> Value {
        if profileWriteHeld {
            await withCheckedContinuation { profileWriteWaiters.append($0) }
        } else {
            profileWriteHeld = true
        }
        defer {
            if profileWriteWaiters.isEmpty {
                profileWriteHeld = false
            } else {
                profileWriteWaiters.removeFirst().resume()   // замок переходит ждущему
            }
        }
        return try await body()
    }
}
