//  ErrorDictionaryTests — К26, К27, К29 (группа З плана MEE-410) и К30 (группа И) перечня
//  MEE-401 (C-016 v10). К28 — снят самим перечнем («перенесён в „Что этот перечень не
//  покрывает“», возврат РП п.5) — номер намеренно пуст, здесь ему нет пары.
//
//  К26 (инв. 19, восемь источников — StorageError, CalendarError, TranscriptionServiceError,
//  ModelCatalogError, AttributionError, CaptureError, PermissionsError, JobQueueError):
//  ДОСТИЖИМО В ЗОНЕ ЭТОЙ ЗАДАЧИ (`AppFacadeImpl*`, группы М–Х не трогать) — ЧЕТЫРЕ ИЗ ВОСЬМИ.
//   • StorageError — `forgetVoiceProfile` (эта задача, ниже).
//   • PermissionsError — `openPermissionSettings` (эта задача, ниже).
//   • CaptureError — `startRecording`, уже покрыт `RecordingCommandsTests.
//     test_wrapCaptureError_codeAndPermissionKindPerCase` (группа В, MEE-420 часть 3/4) —
//     не дублируется здесь.
//   • AttributionError — `assignSpeaker`/`clearSpeaker`, уже покрыт `SpeakerAssignmentTests.
//     test_k18_...` (группы Д/Е, MEE-420 часть 5) — не дублируется здесь.
//  ЧЕТЫРЕ ИЗ ВОСЬМИ — ВНЕ ДОСЯГАЕМОСТИ: CalendarError, TranscriptionServiceError,
//  ModelCatalogError, JobQueueError — ни у одной нет `wrap(_:)` НИГДЕ в `AppFacadeImpl*`, и
//  ни один уже реализованный (в зоне этой задачи) метод фасада не обращается к
//  `CalendarPort`/`TranscriptionServicePort`/`ModelCatalogPort`/`JobQueue` таким образом,
//  чтобы их отказ вообще мог дойти до фасада — естественные потребители (группы М/Н/О плана)
//  вне периметра МЕЕ-437 («группы М–Х — DEV-2, не трогать»). Заводить `wrap(_:)` без единого
//  вызывающего метода значило бы мёртвый код — тот же довод, что заголовок
//  `AppFacadeImpl.swift` уже даёт для `notImplemented`-заглушек.
//
//  К27 (табличный тест словаря): полные таблицы StorageError (6 случаев) и PermissionsError
//  (2 случая) — ниже, обе с колонкой `permissionKind` (возврат РП, приёмка 10:15 UTC,
//  «мелочи» — у обоих источников он всегда `nil`, что сама таблица и проверяет, а не только
//  документирует комментарием). CaptureError (11) и AttributionError (6) — уже полные
//  таблицы в файлах, названных выше. `app.internalError` (заглушка на непойманный
//  контрактом тип ошибки, `wrapUnexpected`) — уже покрыт `AppFacadeImplReadModelsTests+
//  Return.test_inv19_unexpectedPortErrorIsWrappedAsAppInternalError` (через рукописную
//  обёртку `ThrowingOpenSettingsPermissionsPort`, не типизированный фейк) — не дублируется
//  здесь.
//
//  `PermissionsError.loginItemRegistrationFailed` — единственный случай источника внутри
//  ДОСТИЖИМЫХ четырёх, у которого сегодня НЕТ реалистичного вызывающего пути: ни один метод
//  фасада не трогает `PermissionsPort.setLaunchAtLogin` (AppSettings.launchAtLogin пишется
//  только в SettingsRepository, `updateSettings` не прокидывает его в порт прав). Таблица К27
//  ниже впрыскивает его через `openPermissionSettings`/`failOpenSettings(with:for:)` — фейк
//  бросает ЛЮБОЙ заданный `PermissionsError` независимо от места вызова, так что это честно
//  проверяет правило словаря («какой code получает этот case»), но не воспроизводит
//  реалистичный сценарий — отмечено явно, а не выдано за живой К26-вектор.

import XCTest
@testable import DomainCore
import DomainTestKit

final class ErrorDictionaryTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let permissions: FakePermissionsPort
    }

    private func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
        let permissions = FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date())
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: permissions,
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            clock: { Date() }
        )
        return Fixture(facade: facade, repositories: repositories, permissions: permissions)
    }

    // MARK: - К26/К27: StorageError через forgetVoiceProfile (speakerProfiles.delete)

    private struct StorageErrorRow {
        let error: StorageError
        let expectedCode: String
    }

    private var storageErrorRows: [StorageErrorRow] {
        [
            StorageErrorRow(error: .notFound(entity: "SpeakerProfile", id: "x"), expectedCode: "storage.notFound"),
            StorageErrorRow(error: .constraintViolation(message: "m"), expectedCode: "storage.constraintViolation"),
            StorageErrorRow(
                error: .migrationFailed(identifier: "1", message: "m"), expectedCode: "storage.migrationFailed"
            ),
            StorageErrorRow(error: .fileMissing(path: "/tmp/x"), expectedCode: "storage.fileMissing"),
            StorageErrorRow(
                error: .dataCorrupted(entity: "SpeakerProfile", id: "x", message: "m"),
                expectedCode: "storage.dataCorrupted"
            ),
            StorageErrorRow(error: .io(message: "disk full"), expectedCode: "storage.io")
        ]
    }

    /// К26 (инв. 19): `StorageError` брошен фейком `SpeakerProfileRepository` внутри вызова
    /// `forgetVoiceProfile` — наружу уходит только `AppFacadeError.underlying(AppErrorView)`,
    /// сам `StorageError` не выходит ни одним полем (проверено буквально — `catch let ... as
    /// StorageError` провалил бы тест, если бы до него дошло).
    func test_k26_storageError_noLeak_viaForgetVoiceProfile() async throws {
        let fixture = makeFixture()
        let personId = UUID()
        fixture.repositories.speakerProfiles.fail(with: .io(message: "disk full"), on: .delete, id: personId.uuidString)

        do {
            try await fixture.facade.forgetVoiceProfile(personId: personId)
            XCTFail("ожидался отказ")
        } catch let error as StorageError {
            XCTFail("StorageError утёк наружу как есть, в обход словаря §3.1: \(error)")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "storage.io")
        }
    }

    /// К27: все шесть случаев `StorageError` — код строится правилом `storage.<имя case>`;
    /// колонка `permissionKind` (возврат РП, «мелочи») — источник, не про права вовсе,
    /// `nil` на каждой строке.
    func test_k27_storageError_codePerCase_viaForgetVoiceProfile() async throws {
        for row in storageErrorRows {
            let fixture = makeFixture()
            let personId = UUID()
            fixture.repositories.speakerProfiles.fail(with: row.error, on: .delete, id: personId.uuidString)

            do {
                try await fixture.facade.forgetVoiceProfile(personId: personId)
                XCTFail("\(row.error): ожидался отказ")
            } catch AppFacadeError.underlying(let view) {
                XCTAssertEqual(view.code, row.expectedCode, "\(row.error)")
                XCTAssertNil(view.permissionKind, "\(row.error)")
            }
        }
    }

    // MARK: - К26/К27: PermissionsError через openPermissionSettings

    private struct PermissionsErrorRow {
        let error: PermissionsError
        let expectedCode: String
    }

    private var permissionsErrorRows: [PermissionsErrorRow] {
        [
            PermissionsErrorRow(
                error: .settingsPaneUnavailable(kind: .microphone), expectedCode: "permissions.settingsPaneUnavailable"
            ),
            // См. докстринг файла: реалистичного вызывающего пути у этого case сегодня нет —
            // впрыснут тем же фейком, что и первая строка, только чтобы проверить правило
            // словаря, а не живой сценарий.
            PermissionsErrorRow(
                error: .loginItemRegistrationFailed(message: "m"),
                expectedCode: "permissions.loginItemRegistrationFailed"
            )
        ]
    }

    /// К26 (инв. 19): симметрично `test_k26_storageError_noLeak_...` — `PermissionsError` не
    /// выходит наружу как есть.
    func test_k26_permissionsError_noLeak_viaOpenPermissionSettings() async throws {
        let fixture = makeFixture()
        fixture.permissions.failOpenSettings(with: .settingsPaneUnavailable(kind: .microphone), for: .microphone)

        do {
            try await fixture.facade.openPermissionSettings(.microphone)
            XCTFail("ожидался отказ")
        } catch let error as PermissionsError {
            XCTFail("PermissionsError утёк наружу как есть, в обход словаря §3.1: \(error)")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "permissions.settingsPaneUnavailable")
        }
    }

    /// К27: оба случая `PermissionsError`; колонка `permissionKind` — `nil` на обеих строках
    /// (сам `wrap(_:PermissionsError)` не заполняет его ни для одного из двух случаев).
    func test_k27_permissionsError_codePerCase_viaOpenPermissionSettings() async throws {
        for row in permissionsErrorRows {
            let fixture = makeFixture()
            fixture.permissions.failOpenSettings(with: row.error, for: .microphone)

            do {
                try await fixture.facade.openPermissionSettings(.microphone)
                XCTFail("\(row.error): ожидался отказ")
            } catch AppFacadeError.underlying(let view) {
                XCTAssertEqual(view.code, row.expectedCode, "\(row.error)")
                XCTAssertNil(view.permissionKind, "\(row.error)")
            }
        }
    }

    // MARK: - К29 (инв. 24): один и тот же код, синхронный и асинхронный путь — НЕ ПОКРЫТ

    // Возврат РП (приёмка 10:15 UTC, находка 3): первая версия этого файла публиковала
    // `.failure(AppErrorView)` САМА (тестовая сторона строила `AppErrorView` литералом и
    // сама же вызывала `publish(_:)`) и сравнивала код с самой собой — тавтология, а не
    // проверка производственного кода. Честная причина отсутствия теста: сегодня НИ ОДИН
    // производитель `.failure` не существует нигде в domain-core (сверено `grep`'ом по
    // `.failure(...)` в `Packages/Core/Sources/DomainCore` — ноль совпадений, кроме объявления
    // самого случая в `AppFacade.swift`) — асинхронный путь инв. 24 в принципе не с чем
    // сравнивать, пока такого производителя не заведёт своя задача (естественные кандидаты —
    // фоновая обработка ошибок job-очереди/захвата, группы Н/Р, вне зоны этой задачи).
    // К29 остаётся непокрытым по этой причине, а не по недосмотру.

    // MARK: - К30 (инв. 23): permissionKind — признак, не перечень

    /// Вектор 1/5, достижимый: `facade.permissionRequired` несёт `PermissionKind` самим
    /// случаем (не через `AppErrorView` — `AppFacadeError.permissionRequired` не идёт через
    /// `.underlying`). Векторы `capture.systemAudioDenied`/`capture.microphoneDenied` — уже
    /// покрыты `RecordingCommandsTests.test_wrapCaptureError_codeAndPermissionKindPerCase`
    /// (не дублируются здесь). Векторы `calendar.authorizationRequired` (eventkit/stdio) —
    /// ВНЕ ЗОНЫ: ни `syncCalendars()` (throws не объявлен), ни один calendar-throwing метод
    /// (группа О) не реализован в периметре этой задачи — 2 из 5 недостижимы.
    func test_k30_facadePermissionRequired_carriesKind() async throws {
        let fixture = makeFixture()
        fixture.permissions.setStatus(.denied, for: .microphone)

        do {
            _ = try await fixture.facade.startRecording(meetingId: nil)
            XCTFail("ожидался отказ")
        } catch AppFacadeError.permissionRequired(let kind) {
            XCTAssertEqual(kind, .microphone)
        }
    }

    /// Граница признака (§3.1): `permissions.settingsPaneUnavailable` даёт `permissionKind ==
    /// nil`, хотя у самого case `PermissionKind` формально есть, — отказ вызван не состоянием
    /// права. Тот же вывод уже даёт `AppFacadeImplReadModelsTests.
    /// test_k48b_openPermissionSettingsUnavailableGivesNilPermissionKind` (группа Х,
    /// К48(б)) — эта проверка про ДРУГОЙ критерий (К30, группа И), не дубликат по назначению,
    /// хотя код совпадает почти дословно. `capture.systemAudioPromptTimedOut`/
    /// `capture.microphonePromptTimedOut` — та же граница, уже в `captureErrorRows`
    /// (`RecordingCommandsTests.swift`).
    func test_k30_boundary_settingsPaneUnavailable_permissionKindNil() async throws {
        let fixture = makeFixture()
        fixture.permissions.failOpenSettings(with: .settingsPaneUnavailable(kind: .microphone), for: .microphone)

        do {
            try await fixture.facade.openPermissionSettings(.microphone)
            XCTFail("ожидался отказ")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertNil(view.permissionKind)
        }
    }
}
