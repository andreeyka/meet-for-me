//  MEE-320: продолжение `InMemoryFiveRepositoriesTests` — вынесено в свой файл: тело одного
//  тестового класса иначе перерастает предел `file_length` (тот же приём, что развёл
//  `InMemoryRepositoriesTests` и `InMemoryTranscriptRepositoryTests` у MEE-290).
//  `InMemoryConnectorRepository`, `InMemoryMeetingOutputRepository`, `InMemorySettingsRepository`
//  — имена у §«Фейк для тестов» C-010.
//
//  Инвариант, держимый здесь, — 20 (закрытый список `notFound`): у `ConnectorRepository`
//  бросают `setCursor`/`setSyncOutcome`, у `MeetingOutputRepository` — `markUserEdited`, у
//  `SettingsRepository` — ничто. К47 — по вектору на репозиторий.

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryConnectorOutputSettingsTests: XCTestCase {
}

// MARK: - ConnectorRepository: инвариант 20 (К47, К48)

extension InMemoryConnectorOutputSettingsTests {

    func test_mee320_connectorRepository_setCursorAndSetSyncOutcomeThrowNotFound() async throws {
        let repositories = InMemoryRepositories()

        let missing = try await repositories.connectors.all()
        XCTAssertEqual(missing, [])

        do {
            try await repositories.connectors.setCursor("cursor-1", connectorId: "absent")
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound(entity: "Connector", id: "absent"))
        }
        do {
            try await repositories.connectors.setSyncOutcome(
                at: Date(timeIntervalSince1970: 0), error: nil, connectorId: "absent"
            )
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound(entity: "Connector", id: "absent"))
        }
    }

    /// `delete` на отсутствующем `connectorId` — без эффекта, не в списке инварианта 20.
    func test_mee320_connectorRepository_deleteIsNoOpOnMissingAndUpsertRoundTrips() async throws {
        let repositories = InMemoryRepositories()
        try await repositories.connectors.delete(connectorId: "absent")

        let record = connector(id: "c-1")
        try await repositories.connectors.upsert(record)
        try await repositories.connectors.setCursor("cursor-1", connectorId: "c-1")
        try await repositories.connectors.setSyncOutcome(
            at: Date(timeIntervalSince1970: 1_000), error: "timeout", connectorId: "c-1"
        )

        let all = try await repositories.connectors.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.cursor, "cursor-1")
        XCTAssertEqual(all.first?.lastError, "timeout")
        XCTAssertEqual(all.first?.lastSyncAt, Date(timeIntervalSince1970: 1_000))
    }

    /// К47: заданная ошибка бросается ровно на заданном идентификаторе; ДРУГОЙ
    /// идентификатор тем же методом работает как прежде (возврат по приёмке MEE-320 —
    /// вектор был пропущен). Случай — `migrationFailed`, не `dataCorrupted`: К47 обещает
    /// «все шесть случаев `StorageError`», не один.
    func test_mee320_connectorRepository_failsOnNamedMethodAndId() async throws {
        let repositories = InMemoryRepositories()
        try await repositories.connectors.upsert(connector(id: "c-1"))
        try await repositories.connectors.upsert(connector(id: "c-2"))
        let failure = StorageError.migrationFailed(identifier: "v2", message: "колонка cursor отсутствует")
        repositories.connectors.fail(with: failure, on: .setCursor, id: "c-1")

        do {
            try await repositories.connectors.setCursor("cursor-1", connectorId: "c-1")
            XCTFail("ожидался migrationFailed")
        } catch let error as StorageError {
            XCTAssertEqual(error, failure)
        }
        // Тот же метод на ДРУГОМ идентификаторе не отказывает — вектор непустоты отбора.
        try await repositories.connectors.setCursor("cursor-2", connectorId: "c-2")
        let untouched = try await repositories.connectors.all()
        XCTAssertEqual(untouched.first { $0.id == "c-2" }?.cursor, "cursor-2")

        repositories.connectors.clearFailure(on: .setCursor)
        try await repositories.connectors.setCursor("cursor-1", connectorId: "c-1")
        let restored = try await repositories.connectors.all()
        XCTAssertEqual(restored.first { $0.id == "c-1" }?.cursor, "cursor-1", "отказ снимается")
    }

    private func connector(id: String) -> ConnectorRecord {
        ConnectorRecord(
            id: id, type: "eventkit", pluginId: nil, settingsJson: Data(),
            keychainNamespace: "ns", selectedCalendarIds: [], isEnabled: true,
            lastSyncAt: nil, cursor: nil, lastError: nil
        )
    }
}

// MARK: - MeetingOutputRepository: инвариант 20 (К47, К48)

extension InMemoryConnectorOutputSettingsTests {

    func test_mee320_meetingOutputRepository_markUserEditedThrowsNotFoundReadsReturnEmpty() async throws {
        let repositories = InMemoryRepositories()
        let meetingId = UUID()
        let missingOutputId = UUID()

        let empty = try await repositories.meetingOutputs.outputs(meetingId: meetingId)
        XCTAssertEqual(empty, [])

        do {
            try await repositories.meetingOutputs.markUserEdited(outputId: missingOutputId, contentMarkdown: "правка")
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            // Сверяется и entity, и id (возврат по приёмке MEE-320 — прежде сверялся
            // только entity), как словарь «Поведения» C-010 задаёт оба поля.
            XCTAssertEqual(error, .notFound(entity: "MeetingOutput", id: missingOutputId.uuidString))
        }
    }

    /// `markUserEdited` ставит `isUserEdited = true` (шапка файла) и заменяет `contentMarkdown`.
    func test_mee320_meetingOutputRepository_markUserEditedSetsFlagAndReplacesContent() async throws {
        let repositories = InMemoryRepositories()
        let meetingId = UUID()
        let output = output(meetingId: meetingId)
        try await repositories.meetingOutputs.save(output)
        XCTAssertFalse(output.isUserEdited, "вектор непустоты: изначально не помечено")

        try await repositories.meetingOutputs.markUserEdited(outputId: output.id, contentMarkdown: "новый текст")

        let after = try await repositories.meetingOutputs.outputs(meetingId: meetingId)
        XCTAssertEqual(after.first?.contentMarkdown, "новый текст")
        XCTAssertEqual(after.first?.isUserEdited, true)
    }

    /// К47: заданная ошибка — на заданном идентификаторе; ДРУГОЙ идентификатор тем же
    /// методом не задет (возврат по приёмке MEE-320). Случай — `notFound`, не `dataCorrupted`.
    func test_mee320_meetingOutputRepository_failsOnNamedMethodAndId() async throws {
        let repositories = InMemoryRepositories()
        let meetingId = UUID()
        let otherMeetingId = UUID()
        let saved = output(meetingId: meetingId)
        let other = output(meetingId: otherMeetingId)
        try await repositories.meetingOutputs.save(saved)
        try await repositories.meetingOutputs.save(other)
        let failure = StorageError.notFound(entity: "MeetingOutput", id: meetingId.uuidString)
        repositories.meetingOutputs.fail(with: failure, on: .outputs, id: meetingId.uuidString)

        do {
            _ = try await repositories.meetingOutputs.outputs(meetingId: meetingId)
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, failure)
        }
        // Тот же метод на ДРУГОМ идентификаторе — вектор непустоты отбора.
        let survivor = try await repositories.meetingOutputs.outputs(meetingId: otherMeetingId)
        XCTAssertEqual(survivor.map(\.id), [other.id])

        repositories.meetingOutputs.clearFailure(on: .outputs)
        let restored = try await repositories.meetingOutputs.outputs(meetingId: meetingId)
        XCTAssertEqual(restored.map(\.id), [saved.id], "отказ снимается")
    }

    private func output(meetingId: UUID) -> MeetingOutput {
        MeetingOutput(
            id: UUID(), meetingId: meetingId, kind: .summary, engine: "gpt", modelVersion: "v1",
            promptVersion: "p1", contentMarkdown: "исходный текст", structuredJson: nil,
            createdAt: Date(timeIntervalSince1970: 0), isUserEdited: false
        )
    }
}

// MARK: - SettingsRepository: инвариант 20 (К47, К48)

extension InMemoryConnectorOutputSettingsTests {

    /// Инвариант 20: `notFound` этот порт не бросает ни одним методом — `value(forKey:)`
    /// на отсутствующем ключе отдаёт `nil`.
    func test_mee320_settingsRepository_missingKeyReturnsNilNeverThrows() async throws {
        let repositories = InMemoryRepositories()
        let missing = try await repositories.settings.value(forKey: "unknown")
        XCTAssertNil(missing)
    }

    func test_mee320_settingsRepository_setValueRoundTripsAndNilRemovesKey() async throws {
        let repositories = InMemoryRepositories()
        let payload = Data("1".utf8)
        try await repositories.settings.setValue(payload, forKey: "network-only")
        let stored = try await repositories.settings.value(forKey: "network-only")
        XCTAssertEqual(stored, payload)

        try await repositories.settings.setValue(nil, forKey: "network-only")
        let removed = try await repositories.settings.value(forKey: "network-only")
        XCTAssertNil(removed, "nil снимает ключ")
    }

    /// К47: заданная ошибка — на заданном ключе; ДРУГОЙ ключ тем же методом не задет
    /// (возврат по приёмке MEE-320).
    func test_mee320_settingsRepository_failsOnNamedMethodAndId() async throws {
        let repositories = InMemoryRepositories()
        try await repositories.settings.setValue(Data("1".utf8), forKey: "k")
        try await repositories.settings.setValue(Data("2".utf8), forKey: "other")
        let corrupted = StorageError.dataCorrupted(entity: "Setting", id: "k", message: "инвариант 0")
        repositories.settings.fail(with: corrupted, on: .value, id: "k")

        do {
            _ = try await repositories.settings.value(forKey: "k")
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            XCTAssertEqual(error, corrupted)
        }
        // Тот же метод на ДРУГОМ ключе не отказывает — вектор непустоты отбора.
        let untouched = try await repositories.settings.value(forKey: "other")
        XCTAssertEqual(untouched, Data("2".utf8))

        repositories.settings.clearFailure(on: .value)
        let restored = try await repositories.settings.value(forKey: "k")
        XCTAssertEqual(restored, Data("1".utf8), "отказ снимается")
    }

    /// К47: «заданными могут быть все шесть случаев `StorageError`, а не только
    /// `dataCorrupted`» — табличный тест на все шесть (возврат по приёмке MEE-320: было
    /// проверено два случая на все пять новых фейков вместе, здесь закрыты оставшиеся —
    /// `notFound`, `constraintViolation`, `migrationFailed`, `fileMissing` — тем же
    /// `fail(with:on:id:)`, не специализированным ни под один случай).
    func test_mee320_settingsRepository_failAcceptsAllSixStorageErrorCases() async throws {
        let repositories = InMemoryRepositories()
        let cases: [StorageError] = [
            .notFound(entity: "Setting", id: "k"),
            .constraintViolation(message: "ограничение"),
            .migrationFailed(identifier: "v3", message: "колонка отсутствует"),
            .fileMissing(path: "app_settings.value"),
            .dataCorrupted(entity: "Setting", id: "k", message: "не читается"),
            .io(message: "диск занят")
        ]
        for failure in cases {
            repositories.settings.fail(with: failure, on: .setValue, id: "k")
            do {
                try await repositories.settings.setValue(Data("1".utf8), forKey: "k")
                XCTFail("ожидался \(failure)")
            } catch let error as StorageError {
                XCTAssertEqual(error, failure)
            }
            repositories.settings.clearFailure(on: .setValue)
        }
    }
}
