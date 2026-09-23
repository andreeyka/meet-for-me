//  MEE-290 + MEE-319: фейки репозиториев C-010 — `InMemoryMeetingRepository`,
//  `InMemoryRecordingRepository`, `InMemoryTranscriptRepository` и контейнер
//  `InMemoryRepositories`. Имена взяты у §«Фейк для тестов» C-010.
//
//  ЧТО ПРОВЕРЯЕТСЯ. Контракт (C-010 v7, «Фейк для тестов») требует от фейков держать
//  «те же инварианты 4—6, 10—13, 17, 20, 28 и 29… чтобы тест на фейке ловил те же ошибки,
//  что тест на настоящей базе», и дополнение v2 — уметь по команде теста бросить заданную
//  `StorageError` на заданном методе и заданном идентификаторе. Исполнимы сегодня
//  инварианты 6, 7 (MEE-319 — привязка «запись → встреча»), 8, 12, 13, 17, 18, 20, 28 и
//  29 (MEE-319 — `adHoc()`, К86) — они здесь и стоят, по вектору на каждый. Остальные
//  названы в шапках самих фейков как неисполнимые: их субъекты — порты, которых в дереве
//  нет.
//
//  ГРАНИЦА НАЗВАНА: держимые инварианты суть УСТРОЙСТВО фейка, а не их проверка. Проверяются
//  они тестами `storage`, которого не существует.

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryRepositoriesTests: XCTestCase {
}

// Тело разбито на несколько `extension` не по смыслу, а по объёму: `type_body_length`
// SwiftLint (--strict, работа «Core + Mac») считает тело класса и тело каждого
// `extension` порознь, и одним телом весь файл превышал порог 250 строк (274 строки,
// прогон CI). Три блока ниже — те же три раздела, что были в одном теле класса.
extension InMemoryRepositoriesTests {

    // MARK: - Встречи: инвариант 6 (уникальность dedup_key) и инвариант 20 (что бросает)

    func test_mee290_meetingRepository_rejectsDuplicateDedupKey() async throws {
        let repositories = InMemoryRepositories()
        let key = DedupKey.joinUrl("https://zoom.us/j/1234567890", startEpochSeconds: 1_789_119_000)
        let first = MeetingRecord(
            event: MeetingEventFixtures.oneOnOneZoom, dedupKey: key, status: .scheduled, sources: []
        )
        let second = MeetingRecord(
            event: MeetingEventFixtures.withoutConference, dedupKey: key, status: .scheduled, sources: []
        )

        try await repositories.meetings.save(first)
        XCTAssertEqual(repositories.meetings.storedRecords.count, 1, "вектор непустоты: первая легла")

        do {
            try await repositories.meetings.save(second)
            XCTFail("ожидался отказ по инварианту 6")
        } catch let error as StorageError {
            guard case .constraintViolation = error else {
                return XCTFail("ожидался constraintViolation, получено \(error)")
            }
        }
        XCTAssertEqual(repositories.meetings.storedRecords.count, 1, "вторая не легла")

        // Тот же ключ у ТОЙ ЖЕ встречи — не столкновение, а перезапись.
        try await repositories.meetings.save(first)
        XCTAssertEqual(repositories.meetings.storedRecords.count, 1)
        let found = try await repositories.meetings.meeting(dedupKey: key)
        XCTAssertEqual(found?.event.id, MeetingEventFixtures.oneOnOneZoom.id)
    }

    func test_mee290_meetingRepository_setStatusThrowsNotFoundAndReadsReturnNil() async throws {
        let repositories = InMemoryRepositories()
        let absent = UUID()

        // Инвариант 20, первая половина: чтение не бросает.
        let read = try await repositories.meetings.meeting(id: absent)
        XCTAssertNil(read)
        let window = try await repositories.meetings.meetings(
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4e9)
        )
        XCTAssertEqual(window, [], "пустой массив, а не отказ")

        // Вторая половина: метод, обязанный изменить существующую строку, бросает.
        do {
            try await repositories.meetings.setStatus(.armed, meetingId: absent)
            XCTFail("ожидался notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound(entity: "meetings", id: absent.uuidString))
        }
    }

    func test_mee290_meetingRepository_setStatusReplacesOnlyStatus() async throws {
        let repositories = InMemoryRepositories()
        let event = MeetingEventFixtures.oneOnOneZoom
        let source = MeetingSource(
            sourceConnectorId: "eventkit", externalId: "evt-1001", icalUid: nil,
            lastModified: Date(timeIntervalSince1970: 1_789_041_600)
        )
        repositories.meetings.seed([
            MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: [source])
        ])

        try await repositories.meetings.setStatus(.recording, meetingId: event.id)
        let after = try await repositories.meetings.meeting(id: event.id)
        let updated = try XCTUnwrap(after, "запись на месте")
        XCTAssertEqual(updated.status, MeetingStatus.recording, "статус сменился")
        XCTAssertEqual(after?.sources, [source], "источники не тронуты")
        XCTAssertEqual(after?.event, event, "событие не тронуто")
    }

    // MARK: - Заданный тестом отказ (C-010 v2) — на методе и на идентификаторе

    func test_mee290_meetingRepository_failsOnNamedMethodAndId() async throws {
        let repositories = InMemoryRepositories()
        let event = MeetingEventFixtures.oneOnOneZoom
        let other = MeetingEventFixtures.withoutConference
        repositories.meetings.seed([
            MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: []),
            MeetingRecord(event: other, dedupKey: nil, status: .scheduled, sources: [])
        ])
        let corrupted = StorageError.dataCorrupted(
            entity: "meetings", id: event.id.uuidString, message: "инвариант 0, path=start"
        )
        repositories.meetings.fail(with: corrupted, on: .meetingById, id: event.id.uuidString)

        do {
            _ = try await repositories.meetings.meeting(id: event.id)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            XCTAssertEqual(error, corrupted)
        }

        // Тот же метод на ДРУГОМ идентификаторе не отказывает — вектор непустоты отбора.
        let survivor = try await repositories.meetings.meeting(id: other.id)
        XCTAssertEqual(survivor?.event.id, other.id)

        repositories.meetings.clearFailure(on: .meetingById)
        let restored = try await repositories.meetings.meeting(id: event.id)
        XCTAssertEqual(restored?.event.id, event.id, "отказ снимается")
    }
}

extension InMemoryRepositoriesTests {

    // MARK: - Записи: инвариант 13, предикат `unfinalized()`, каскад инварианта 8

    /// Инвариант 13 C-010 держится БЕЗ единой строки в фейке, и это замер, а не рассуждение:
    /// значения, нарушающего его, не существует — `RecordingManifest.validate()` отвергает
    /// имя каталога, не равное `recordingId.uuidString` (C-002, инвариант 7). Проверка в
    /// `save` была бы зелена по построению, и потому её там нет.
    func test_mee290_recordingRepository_directoryNameInvariantIsUnbreakableByType() async throws {
        let repositories = InMemoryRepositories()
        let good = RecordingRecord(manifest: RecordingManifestFixtures.hourlyTwoChannels, status: .finalized)
        try await repositories.recordings.save(good)
        XCTAssertEqual(repositories.recordings.storedRecords.count, 1, "вектор непустоты: годная запись легла")

        // Вектор: собрать манифест с чужим именем каталога не удаётся вовсе — отказ приходит
        // от ТИПА, а не от репозитория, и приходит ДО всякого его вызова.
        let manifest = RecordingManifestFixtures.hourlyTwoChannels
        assertInvariant(
            try RecordingManifest(
                recordingId: manifest.recordingId,
                meetingId: manifest.meetingId,
                directoryName: "чужое-имя-каталога",
                startedAt: manifest.startedAt,
                endedAt: manifest.endedAt,
                tracks: manifest.tracks,
                markers: manifest.markers,
                capturedProcesses: manifest.capturedProcesses,
                captureGroupKey: manifest.captureGroupKey,
                inputDevices: manifest.inputDevices,
                discontinuities: manifest.discontinuities,
                isFinalized: manifest.isFinalized
            ),
            contract: "C-002",
            type: "RecordingManifest",
            invariant: 7,
            path: "directoryName"
        )
        XCTAssertEqual(repositories.log.count(port: "RecordingRepository", method: "save(_:)"), 1,
                       "второго вызова не было: значение до порта не доехало")
    }

    /// К85 (дельта К MEE-189, инвариант 28) — вход ЧЕРЕЗ `save()`, а не `seed()`, как
    /// действующая редакция и требует (правлено по возврату РП на приёмке MEE-319, PR #55).
    /// Заодно перебор по ВСЕМУ `RecordingStatus` — способ `З`: `RecordingStatus` не
    /// `CaseIterable`, перечень назван здесь и сверен с длиной ответа.
    func test_mee290_recordingRepository_unfinalizedIsEverythingButFinalized() async throws {
        let repositories = InMemoryRepositories()
        let statuses: [RecordingStatus] = [.recording, .stopping, .finalized, .failed]
        let manifests = [
            RecordingManifestFixtures.hourlyTwoChannels,
            RecordingManifestFixtures.deviceChangedMidway,
            RecordingManifestFixtures.unfinished,
            RecordingManifestFixtures.micOnly
        ]
        XCTAssertEqual(statuses.count, manifests.count, "вектор непустоты: на каждый статус своя запись")
        for (manifest, status) in zip(manifests, statuses) {
            try await repositories.recordings.save(RecordingRecord(manifest: manifest, status: status))
        }
        XCTAssertEqual(repositories.recordings.storedRecords.count, 4, "легли все четыре")

        let unfinalized = try await repositories.recordings.unfinalized()
        XCTAssertEqual(unfinalized.count, 3, "три из четырёх")
        XCTAssertEqual(
            unfinalized.map(\.status.rawValue).sorted(),
            ["failed", "recording", "stopping"],
            "не `.finalized` — предикат целиком"
        )
        XCTAssertFalse(
            unfinalized.contains { $0.status == .finalized },
            "финализованная не приходит"
        )
    }

    func test_mee290_recordingRepository_deleteCascadesToTranscripts() async throws {
        let repositories = InMemoryRepositories()
        let manifest = RecordingManifestFixtures.hourlyTwoChannels
        try await repositories.recordings.save(RecordingRecord(manifest: manifest, status: .finalized))
        let transcript = try transcript(for: manifest.recordingId)
        let header = try await repositories.transcripts.save(transcript)

        // Вектор непустоты: до удаления заголовок и сегменты есть.
        let before = try await repositories.transcripts.headers(recordingId: manifest.recordingId)
        XCTAssertEqual(before.count, 1)
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        XCTAssertFalse(rows.isEmpty, "сегменты записаны — каскаду есть что уносить")

        try await repositories.recordings.delete(recordingId: manifest.recordingId, deleteFiles: true)

        let afterHeaders = try await repositories.transcripts.headers(recordingId: manifest.recordingId)
        let afterRows = try await repositories.transcripts.segments(transcriptId: header.id)
        let afterBody = try await repositories.transcripts.transcript(id: header.id)
        XCTAssertEqual(afterHeaders, [])
        XCTAssertEqual(afterRows, [])
        XCTAssertNil(afterBody)
        XCTAssertEqual(
            repositories.recordings.directoriesAskedToDelete, [manifest.directoryName],
            "каталог назван — файлов у фейка нет, наблюдаемо намерение"
        )
    }

    // MARK: - MEE-319: привязка «запись → встреча» (инвариант 7) и adHoc() (инвариант 29)

    /// К86 (i)–(iii), проверенные одновременно, как требует действующая редакция критерия
    /// (дельта К перечня MEE-189): `adHoc()` возвращает ровно записи без привязки к
    /// встрече — ad-hoc с рождения (i), запись, чья встреча удалена каскадом (ii), и
    /// ad-hoc-запись в ТЕРМИНАЛЬНОМ статусе `.finalized` (iii) — метод не смотрит ни на
    /// происхождение, ни на `status`.
    func test_mee319_recordingRepository_adHocReturnsAllThreeK86InputsRegardlessOfStatus() async throws {
        let repositories = InMemoryRepositories()

        // (i) ad-hoc с рождения, статус нетерминальный.
        let fromBirth = RecordingManifestFixtures.hourlyTwoChannels
        XCTAssertNil(fromBirth.meetingId, "вектор непустоты: фикстура ad-hoc с рождения")
        try await repositories.recordings.save(RecordingRecord(manifest: fromBirth, status: .recording))

        // (ii) была привязана к встрече, встреча удалена каскадом: привязка снята,
        // `manifest.meetingId` по-прежнему хранит старый идентификатор (проверяется ниже).
        let meeting = MeetingRecord(
            event: MeetingEventFixtures.oneOnOneZoom, dedupKey: nil, status: .scheduled, sources: []
        )
        try await repositories.meetings.save(meeting)
        let wasBound = try withMeetingId(RecordingManifestFixtures.deviceChangedMidway, meeting.event.id)
        try await repositories.recordings.save(RecordingRecord(manifest: wasBound, status: .stopping))
        try await repositories.meetings.delete(meetingIds: [meeting.event.id])

        // (iii) ad-hoc с рождения, статус ТЕРМИНАЛЬНЫЙ — .finalized.
        let finalizedFromBirth = RecordingManifestFixtures.unfinished
        XCTAssertNil(finalizedFromBirth.meetingId, "вектор непустоты: тоже ad-hoc с рождения")
        try await repositories.recordings.save(
            RecordingRecord(manifest: finalizedFromBirth, status: .finalized)
        )

        let adHoc = try await repositories.recordings.adHoc()
        XCTAssertEqual(
            Set(adHoc.map(\.manifest.recordingId)),
            [fromBirth.recordingId, wasBound.recordingId, finalizedFromBirth.recordingId],
            "все три входа К86, и никого больше"
        )
        XCTAssertTrue(
            adHoc.contains { $0.manifest.recordingId == finalizedFromBirth.recordingId && $0.status == .finalized },
            "К86 (iii): терминальный статус не исключается adHoc()"
        )

        // Манифест (ii) каскад не трогает — обнуляется привязка, а не DTO.
        let stillStale = try await repositories.recordings.recording(id: wasBound.recordingId)
        XCTAssertEqual(
            stillStale?.manifest.meetingId, meeting.event.id,
            "manifest.meetingId переживает каскад устаревшим — инвариант 7, половина «манифест»"
        )
    }

    /// Инвариант 7, половина «колонка»: после каскада `recordings(meetingId:)` по СТАРОМУ
    /// идентификатору отдаёт пусто — привязка снята, хотя `manifest.meetingId` записи
    /// по-прежнему хранит его. Метод читает привязку, а не манифест.
    func test_mee319_recordingRepository_recordingsByMeetingReadsBindingNotManifest() async throws {
        let repositories = InMemoryRepositories()
        let meeting = MeetingRecord(
            event: MeetingEventFixtures.withoutConference, dedupKey: nil, status: .scheduled, sources: []
        )
        try await repositories.meetings.save(meeting)
        let manifest = try withMeetingId(RecordingManifestFixtures.micOnly, meeting.event.id)
        try await repositories.recordings.save(RecordingRecord(manifest: manifest, status: .recording))

        // Вектор непустоты: до каскада запись находится по встрече.
        let before = try await repositories.recordings.recordings(meetingId: meeting.event.id)
        XCTAssertEqual(before.map(\.manifest.recordingId), [manifest.recordingId])

        try await repositories.meetings.delete(meetingIds: [meeting.event.id])

        let after = try await repositories.recordings.recordings(meetingId: meeting.event.id)
        XCTAssertEqual(after, [], "привязка снята каскадом — читаем колонку, не манифест")
    }

    /// Запись, привязанная к ЖИВОЙ (не удалённой) встрече, в `adHoc()` не попадает:
    /// предикат не путает «привязки никогда не было» с «встреча ещё существует».
    func test_mee319_recordingRepository_adHocExcludesRecordingBoundToLiveMeeting() async throws {
        let repositories = InMemoryRepositories()
        let meeting = MeetingRecord(
            event: MeetingEventFixtures.cancelled, dedupKey: nil, status: .scheduled, sources: []
        )
        try await repositories.meetings.save(meeting)
        let manifest = try withMeetingId(RecordingManifestFixtures.sleepDuringRecording, meeting.event.id)
        try await repositories.recordings.save(RecordingRecord(manifest: manifest, status: .recording))

        let adHoc = try await repositories.recordings.adHoc()
        XCTAssertTrue(adHoc.isEmpty, "встреча жива — привязка держится, запись не ad-hoc")
    }
}

extension InMemoryRepositoriesTests {

    // MARK: - Контейнер: один журнал на три порта

    func test_mee290_container_sharesOneCallLog() async throws {
        let repositories = InMemoryRepositories()
        XCTAssertTrue(repositories.log.isEmpty, "вектор непустоты: журнал начинается пустым")

        _ = try await repositories.meetings.meeting(id: UUID())
        _ = try await repositories.recordings.unfinalized()
        _ = try await repositories.transcripts.headers(recordingId: UUID())

        XCTAssertEqual(
            repositories.log.signatures,
            [
                "MeetingRepository.meeting(id:)",
                "RecordingRepository.unfinalized()",
                "TranscriptRepository.headers(recordingId:)"
            ],
            "три порта в одной последовательности"
        )
    }

    // MARK: - Оснастка

    /// Копия фикстуры с заданным `meetingId` — все фикстуры `RecordingManifestFixtures`
    /// заведены с `meetingId == nil` (ad-hoc), и тестам инварианта 7 нужна привязанная
    /// версия той же формы, без нового набора фикстур ради одного поля.
    private func withMeetingId(_ manifest: RecordingManifest, _ meetingId: UUID) throws -> RecordingManifest {
        try RecordingManifest(
            recordingId: manifest.recordingId,
            meetingId: meetingId,
            directoryName: manifest.directoryName,
            startedAt: manifest.startedAt,
            endedAt: manifest.endedAt,
            tracks: manifest.tracks,
            markers: manifest.markers,
            capturedProcesses: manifest.capturedProcesses,
            captureGroupKey: manifest.captureGroupKey,
            inputDevices: manifest.inputDevices,
            discontinuities: manifest.discontinuities,
            isFinalized: manifest.isFinalized
        )
    }

    /// Транскрипт с двумя сегментами, несущими искомую подстроку, и одним без неё.
    private func transcript(for recordingId: UUID) throws -> Transcript {
        try Transcript(
            recordingId: recordingId,
            language: "ru",
            engine: "gigaam",
            modelVersion: "v2",
            createdAt: Date(timeIntervalSince1970: 1_789_120_800),
            segments: [
                try segment(startMs: 0, endMs: 1_000, text: "первое слово здесь"),
                try segment(startMs: 1_000, endMs: 2_000, text: "второе слово тоже"),
                try segment(startMs: 2_000, endMs: 3_000, text: "третий без совпадения")
            ],
            speakers: []
        )
    }

    private func segment(startMs: Int, endMs: Int, text: String) throws -> Transcript.Segment {
        try Transcript.Segment(
            startMs: startMs,
            endMs: endMs,
            channel: .mic,
            speakerCluster: nil,
            text: text,
            textOriginal: nil,
            textConfidence: nil,
            words: []
        )
    }
}
