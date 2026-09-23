//  MEE-320: пять фейков `InMemoryRepositories`, дописанных после MEE-319 —
//  `InMemoryPersonRepository`, `InMemorySpeakerProfileRepository`, `InMemoryConnectorRepository`,
//  `InMemoryMeetingOutputRepository`, `InMemorySettingsRepository`. Имена — у §«Фейк для
//  тестов» C-010.
//
//  ЧТО ПРОВЕРЯЕТСЯ. К48 (действующая редакция, дельта К MEE-189): «фейки держат инварианты
//  4—6, 10—13, 17, 20, 28 и 29… в своей части». Для этих пяти это инварианты 4 (persons),
//  5 (person_emails), 11 (speaker_profiles.embedding — зелено по построению, шапка
//  `InMemorySpeakerProfileRepository.swift`) и 20 (закрытый список `notFound`) — по каждому
//  вектор в своём разделе ниже. К47: каждый из восьми фейков умеет бросить заданную
//  `StorageError` на заданном методе и заданном идентификаторе — по одному вектору на
//  репозиторий, три существующих уже покрыты `InMemoryRepositoriesTests`/
//  `InMemoryTranscriptRepositoryTests`.
//
//  ГРАНИЦА НАЗВАНА: держимые инварианты суть УСТРОЙСТВО фейка, а не их проверка.

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryFiveRepositoriesTests: XCTestCase {
}

// MARK: - PersonRepository: инварианты 4, 5, 20 (К47, К48)

extension InMemoryFiveRepositoriesTests {

    /// Инвариант 4, вектор К7 (i): `setMe(A)`, затем `setMe(B)` — ровно одна строка
    /// с `is_me`, и это `B`; `me()` возвращает `B`.
    func test_mee320_personRepository_setMeKeepsAtMostOneFlagged() async throws {
        let repositories = InMemoryRepositories()
        let personA = try await repositories.persons.upsert(displayName: "Аня", emails: ["a@e.example"])
        let personB = try await repositories.persons.upsert(displayName: "Боря", emails: ["b@e.example"])

        try await repositories.persons.setMe(personId: personA)
        try await repositories.persons.setMe(personId: personB)

        let all = try await repositories.persons.persons(ids: [personA, personB])
        XCTAssertEqual(all.filter(\.isMe).map(\.id), [personB], "ровно одна строка с is_me, и это B")
        let me = try await repositories.persons.me()
        XCTAssertEqual(me?.id, personB)
    }

    /// Инвариант 20: `rename`/`setMe` бросают `notFound` на отсутствующей строке; чтения
    /// отдают `nil`/пустой массив.
    func test_mee320_personRepository_renameAndSetMeThrowNotFoundReadsReturnNil() async throws {
        let repositories = InMemoryRepositories()
        let absent = UUID()

        let byId = try await repositories.persons.person(id: absent)
        XCTAssertNil(byId)
        let byEmail = try await repositories.persons.person(email: "nobody@e.example")
        XCTAssertNil(byEmail)
        let many = try await repositories.persons.persons(ids: [absent])
        XCTAssertEqual(many, [])

        do {
            try await repositories.persons.rename(personId: absent, displayName: "Кто-то")
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound(entity: "Person", id: absent.uuidString))
        }
        do {
            try await repositories.persons.setMe(personId: absent)
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound(entity: "Person", id: absent.uuidString))
        }
    }

    /// К8: второй `upsert` тем же (нормализованным) email переносит адрес и оставляет одну
    /// строку — устройство фейка выбрано шапкой `InMemoryPersonRepository.swift` (СТРОКА).
    /// Регистр нормализован: `X@E.example` и `x@e.example` — один адрес.
    func test_mee320_personRepository_upsertTransfersEmailAndStaysOneRow() async throws {
        let repositories = InMemoryRepositories()
        let first = try await repositories.persons.upsert(displayName: "Аня", emails: ["x@e.example"])
        let second = try await repositories.persons.upsert(displayName: "Боря", emails: ["X@E.example"])

        XCTAssertEqual(first, second, "перенос — одна и та же строка, а не две")
        XCTAssertEqual(repositories.persons.storedRecords.count, 1, "одна строка person_emails/person")
        let resolved = try await repositories.persons.person(email: "x@e.example")
        XCTAssertEqual(resolved?.displayName, "Боря", "последний upsert выиграл имя")
    }

    /// Адреса ДОБАВЛЯЮТСЯ повторным `upsert`, а не заменяются (возврат по приёмке MEE-320 —
    /// шапка `InMemoryPersonRepository.swift` называла это дословно, код заменял список
    /// целиком). Второй вызов того же человека с НОВЫМ адресом обязан оставить прежний
    /// разрешимым.
    func test_mee320_personRepository_upsertAddsEmailsRatherThanReplacing() async throws {
        let repositories = InMemoryRepositories()
        let identifier = try await repositories.persons.upsert(displayName: "Аня", emails: ["a@e.example"])
        let again = try await repositories.persons.upsert(displayName: "Аня", emails: ["a2@e.example"])
        XCTAssertEqual(identifier, again, "тот же человек — тот же email разрешает владельца")

        let byOldEmail = try await repositories.persons.person(email: "a@e.example")
        XCTAssertEqual(byOldEmail?.id, identifier, "старый адрес по-прежнему разрешим")
        let byNewEmail = try await repositories.persons.person(email: "a2@e.example")
        XCTAssertEqual(byNewEmail?.id, identifier, "новый добавлен")
        XCTAssertEqual(Set(byOldEmail?.emails ?? []), ["a@e.example", "a2@e.example"], "оба адреса на одной записи")
    }

    /// Инвариант 5: `upsert`, чьи адреса указывают на ДВУХ РАЗНЫХ существующих людей,
    /// сливать их не может — `constraintViolation` (возврат по приёмке MEE-320: развилка
    /// К8 названа шапкой, но самим столкновением проверена не была).
    func test_mee320_personRepository_upsertRejectsMergeOfTwoDifferentOwners() async throws {
        let repositories = InMemoryRepositories()
        let alice = try await repositories.persons.upsert(displayName: "Аня", emails: ["a@e.example"])
        let bob = try await repositories.persons.upsert(displayName: "Боря", emails: ["b@e.example"])

        do {
            _ = try await repositories.persons.upsert(displayName: "Слияние", emails: ["a@e.example", "b@e.example"])
            XCTFail("ожидался constraintViolation")
        } catch let error as StorageError {
            guard case .constraintViolation = error else {
                return XCTFail("ожидался constraintViolation, получено \(error)")
            }
        }
        // Обе записи целы, ни одна не изменена и не слита.
        let stillAlice = try await repositories.persons.person(id: alice)
        let stillBob = try await repositories.persons.person(id: bob)
        XCTAssertEqual(stillAlice?.displayName, "Аня")
        XCTAssertEqual(stillBob?.displayName, "Боря")
        XCTAssertEqual(repositories.persons.storedRecords.count, 2, "слияния не случилось")
    }

    /// К47 на новом репозитории: заданная `StorageError` бросается ровно на заданном методе
    /// и идентификаторе; ДРУГОЙ идентификатор тем же методом не задет (возврат по приёмке
    /// MEE-320 — этот вектор был пропущен); отказ снимается.
    func test_mee320_personRepository_failsOnNamedMethodAndId() async throws {
        let repositories = InMemoryRepositories()
        let identifier = try await repositories.persons.upsert(displayName: "Аня", emails: ["a@e.example"])
        let other = try await repositories.persons.upsert(displayName: "Боря", emails: ["b@e.example"])
        let corrupted = StorageError.dataCorrupted(
            entity: "Person", id: identifier.uuidString, message: "инвариант 0, path=displayName"
        )
        repositories.persons.fail(with: corrupted, on: .personById, id: identifier.uuidString)

        do {
            _ = try await repositories.persons.person(id: identifier)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            XCTAssertEqual(error, corrupted)
        }
        let byEmail = try await repositories.persons.person(email: "a@e.example")
        XCTAssertEqual(byEmail?.id, identifier, "другой метод не задет")
        // Тот же метод на ДРУГОМ идентификаторе — вектор непустоты отбора.
        let untouched = try await repositories.persons.person(id: other)
        XCTAssertEqual(untouched?.id, other)

        repositories.persons.clearFailure(on: .personById)
        let restored = try await repositories.persons.person(id: identifier)
        XCTAssertEqual(restored?.id, identifier, "отказ снимается")
    }
}

// MARK: - SpeakerProfileRepository: инвариант 11 (зелено по построению), 20 (К47, К48)

extension InMemoryFiveRepositoriesTests {

    /// Инвариант 11 держится без единой строки в фейке (шапка файла): значения `[Float]`,
    /// нарушающего «длина ровно count * 4 байта», не существует. Замер — вектором:
    /// произвольная длина эмбеддинга сохраняется и читается как есть, без урезания.
    func test_mee320_speakerProfileRepository_embeddingLengthInvariantIsUnbreakableByType() async throws {
        let repositories = InMemoryRepositories()
        let personId = UUID()
        let profile = SpeakerProfile(
            personId: personId, embedding: [Float](repeating: 0.5, count: 192),
            modelVersion: "v1", sampleCount: 3, updatedAt: Date(timeIntervalSince1970: 0)
        )
        try await repositories.speakerProfiles.upsert(profile)

        let stored = try await repositories.speakerProfiles.profile(personId: personId, modelVersion: "v1")
        XCTAssertEqual(stored?.embedding.count, 192, "длина не урезана и не дополнена")
    }

    /// Инвариант 20: `delete`/`deleteAll` на отсутствующем ключе — без эффекта, не отказ;
    /// чтения отдают `nil`/пустой массив.
    func test_mee320_speakerProfileRepository_deleteIsNoOpOnMissingReadsReturnNil() async throws {
        let repositories = InMemoryRepositories()
        let personId = UUID()

        let missing = try await repositories.speakerProfiles.profile(personId: personId, modelVersion: "v1")
        XCTAssertNil(missing)
        let none = try await repositories.speakerProfiles.profiles(personIds: [personId], modelVersion: "v1")
        XCTAssertEqual(none, [])

        try await repositories.speakerProfiles.delete(personId: personId)
        try await repositories.speakerProfiles.deleteAll(modelVersion: "v1")
        // Ни один вызов не бросил — сам факт, что мы дошли досюда, и есть утверждение.
    }

    /// `delete(personId:)` снимает все версии человека; `deleteAll(modelVersion:)` — одну
    /// версию у всех людей. Два разных среза одного хранилища (шапка файла).
    func test_mee320_speakerProfileRepository_deleteAndDeleteAllUseDifferentSlices() async throws {
        let repositories = InMemoryRepositories()
        let alice = UUID()
        let bob = UUID()
        try await repositories.speakerProfiles.upsert(profile(personId: alice, modelVersion: "v1"))
        try await repositories.speakerProfiles.upsert(profile(personId: alice, modelVersion: "v2"))
        try await repositories.speakerProfiles.upsert(profile(personId: bob, modelVersion: "v1"))
        XCTAssertEqual(repositories.speakerProfiles.storedProfiles.count, 3, "вектор непустоты")

        try await repositories.speakerProfiles.delete(personId: alice)
        let afterDelete = repositories.speakerProfiles.storedProfiles
        XCTAssertEqual(afterDelete.map(\.personId), [bob], "обе версии alice ушли")

        try await repositories.speakerProfiles.upsert(profile(personId: alice, modelVersion: "v1"))
        try await repositories.speakerProfiles.deleteAll(modelVersion: "v1")
        let afterDeleteAll = repositories.speakerProfiles.storedProfiles
        XCTAssertTrue(afterDeleteAll.isEmpty, "v1 снята у всех, v2 alice уже не было")
    }

    /// К47 на новом репозитории: заданная ошибка — на заданном идентификаторе; ДРУГОЙ
    /// идентификатор тем же методом не задет (возврат по приёмке MEE-320). Случай —
    /// `fileMissing`, не `dataCorrupted`: К47 обещает «все шесть случаев `StorageError`».
    func test_mee320_speakerProfileRepository_failsOnNamedMethodAndId() async throws {
        let repositories = InMemoryRepositories()
        let personId = UUID()
        let otherPersonId = UUID()
        try await repositories.speakerProfiles.upsert(profile(personId: personId, modelVersion: "v1"))
        try await repositories.speakerProfiles.upsert(profile(personId: otherPersonId, modelVersion: "v1"))
        let failure = StorageError.fileMissing(path: "models/ru/embedding.bin")
        repositories.speakerProfiles.fail(with: failure, on: .profile, id: personId.uuidString)

        do {
            _ = try await repositories.speakerProfiles.profile(personId: personId, modelVersion: "v1")
            XCTFail("ожидался fileMissing")
        } catch let error as StorageError {
            XCTAssertEqual(error, failure)
        }
        // Тот же метод на ДРУГОМ идентификаторе — вектор непустоты отбора.
        let untouched = try await repositories.speakerProfiles.profile(personId: otherPersonId, modelVersion: "v1")
        XCTAssertEqual(untouched?.personId, otherPersonId)

        repositories.speakerProfiles.clearFailure(on: .profile)
        let restored = try await repositories.speakerProfiles.profile(personId: personId, modelVersion: "v1")
        XCTAssertEqual(restored?.personId, personId, "отказ снимается")
    }

    private func profile(personId: UUID, modelVersion: String) -> SpeakerProfile {
        SpeakerProfile(
            personId: personId, embedding: [0.1, 0.2, 0.3], modelVersion: modelVersion,
            sampleCount: 1, updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
