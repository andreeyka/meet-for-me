//  PermissionsReadyTests — К31, К32 перечня MEE-401 (C-016 v10), группа К плана MEE-410.
//  МЕЕ-437: `permissionsReady` — новая логика (`AppFacadeImpl+PermissionsReadiness.swift`),
//  не только тест уже существовавшего вычисления — до этой задачи `status()` отдавал
//  `.notReady` литералом (см. заголовок `AppFacadeImpl.swift`, редакция до МЕЕ-437).
//
//  К31 «синтетический седьмой случай» (тотальность): контракт просит подтвердить, что
//  право, не названное явно, попадает в обязательные по умолчанию. `isPermissionRequired`
//  и `readinessBucket` — оба `switch` БЕЗ `default:` (см. сам файл реализации) — это и есть
//  механизм тотальности: седьмой случай `PermissionKind` не пройдёт компиляцию, пока кто-то
//  не отнесёт его к одной из веток, а не проверка чтением значения во время исполнения.
//  Добавить его тестовой стороной, не трогая C-007 (реальное перечисление), нельзя — здесь
//  вместо этого `test_k31_totality_allCasesCountGuardsSwitchExhaustiveness` фиксирует текущее
//  число случаев (6), чтобы правка C-007 без правки этого файла сначала уронила именно тест,
//  а не осталась незамеченной.

import XCTest
@testable import DomainCore
import DomainTestKit

final class PermissionsReadyTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let permissions: FakePermissionsPort
    }

    private func makeFixture(startingStatus: PermissionStatus = .granted) -> Fixture {
        let repositories = InMemoryRepositories()
        let permissions = FakePermissionsPort(
            startingStatus: startingStatus, startingOutcome: .granted, checkedAt: Date(timeIntervalSince1970: 0)
        )
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
            connectors: repositories.connectors,
            clock: { Date(timeIntervalSince1970: 0) }
        )
        return Fixture(facade: facade, permissions: permissions)
    }

    // MARK: - К31 (инв. 25): обязательность по PermissionKind × RecordingPolicy

    private struct RequiredRow {
        let kind: PermissionKind
        let policy: AppSettings.RecordingPolicy
        let expected: Bool
    }

    private var requiredRows: [RequiredRow] {
        var rows: [RequiredRow] = []
        for policy in [AppSettings.RecordingPolicy.ask, .auto, .manual] {
            rows.append(RequiredRow(kind: .microphone, policy: policy, expected: true))
            rows.append(RequiredRow(kind: .systemAudioRecording, policy: policy, expected: true))
            rows.append(RequiredRow(kind: .notifications, policy: policy, expected: policy == .ask))
            rows.append(RequiredRow(kind: .screenRecording, policy: policy, expected: false))
            rows.append(RequiredRow(kind: .calendars, policy: policy, expected: false))
            rows.append(RequiredRow(kind: .accessibility, policy: policy, expected: false))
        }
        return rows
    }

    func test_k31_isPermissionRequired_perKindAndPolicy() async {
        let fixture = makeFixture()
        for row in requiredRows {
            let settings = settingsWith(recordingPolicy: row.policy)
            let actual = await fixture.facade.isPermissionRequired(row.kind, settings: settings)
            XCTAssertEqual(actual, row.expected, "\(row.kind) при \(row.policy)")
        }
    }

    /// Т. к сумме требуемых прав К31/К32: `PermissionKind.allCases` читается самим
    /// вычислением (не отдельной копией) — эта проверка ловит только рассинхронизацию
    /// СЧЁТА, оставляя саму тотальность компилятору (см. докстринг файла).
    func test_k31_totality_allCasesCountGuardsSwitchExhaustiveness() {
        XCTAssertEqual(
            PermissionKind.allCases.count, 6,
            "новый случай PermissionKind ломает компиляцию switch в isPermissionRequired/readinessBucket " +
            "(нет default:) раньше, чем эту проверку — она лишь документирует ожидаемое число"
        )
    }

    // MARK: - К32 (инв. 26): (а)/(б)/(в) — ступени готовности

    /// (а): хотя бы одно обязательное право блокирующее (`.denied`) — `.notReady`, даже когда
    /// остальные обязательные выданы.
    func test_k32_vectorA_oneBlockingRequiredPermission_notReady() async {
        let fixture = makeFixture(startingStatus: .granted)
        fixture.permissions.setStatus(.denied, for: .microphone)
        let settings = settingsWith(recordingPolicy: .ask)
        let snapshot = await fixture.permissions.snapshot()
        let readiness = await fixture.facade.permissionsReady(snapshot: snapshot, settings: settings)
        XCTAssertEqual(readiness, .notReady)
    }

    /// (а), возврат РП (приёмка 10:15 UTC, «мелочи»): `.denied` — не единственный блокирующий
    /// статус — `readinessBucket` относит к нему все четыре (`.notDetermined`/`.denied`/
    /// `.restricted`/`.unavailable`), а тест выше проверял только один из четырёх.
    func test_k32_vectorA_everyBlockingStatus_notReady() async {
        for status in [PermissionStatus.notDetermined, .denied, .restricted, .unavailable] {
            let fixture = makeFixture(startingStatus: .granted)
            fixture.permissions.setStatus(status, for: .microphone)
            let settings = settingsWith(recordingPolicy: .ask)
            let snapshot = await fixture.permissions.snapshot()
            let readiness = await fixture.facade.permissionsReady(snapshot: snapshot, settings: settings)
            XCTAssertEqual(readiness, .notReady, "\(status)")
        }
    }

    /// (а), возврат РП: блокирующее перевешивает «неизвестное» на РАЗНЫХ правах одного и
    /// того же снимка — К31/К32 сами называют это порядком ступеней, отдельно от того, что
    /// каждая ступень достижима в одиночку.
    func test_k32_vectorA_blockingOutweighsUnknownAcrossDifferentPermissions_notReady() async {
        let fixture = makeFixture(startingStatus: .granted)
        fixture.permissions.setStatus(.denied, for: .microphone)
        fixture.permissions.setStatus(.unknown, for: .systemAudioRecording)
        let settings = settingsWith(recordingPolicy: .ask)
        let snapshot = await fixture.permissions.snapshot()
        let readiness = await fixture.facade.permissionsReady(snapshot: snapshot, settings: settings)
        XCTAssertEqual(readiness, .notReady)
    }

    /// Необязательное право (`screenRecording`) — `.denied` его не блокирует: `.ready`
    /// остаётся `.ready`, потому что это право не входит ни в один обязательный набор
    /// (К31), какое бы состояние оно ни несло.
    func test_k32_deniedNonRequiredPermission_stillReady() async {
        let fixture = makeFixture(startingStatus: .granted)
        fixture.permissions.setStatus(.denied, for: .screenRecording)
        let settings = settingsWith(recordingPolicy: .auto)
        let snapshot = await fixture.permissions.snapshot()
        let readiness = await fixture.facade.permissionsReady(snapshot: snapshot, settings: settings)
        XCTAssertEqual(readiness, .ready)
    }

    /// Возврат РП (приёмка 10:15 UTC, находка 2): связка `status()` → `permissionsReady`
    /// (`AppFacadeImpl.swift`) — а не только сам расчёт, который зовут остальные тесты этого
    /// файла напрямую (`fixture.facade.permissionsReady(snapshot:settings:)`, минуя
    /// `status()` вовсе). Подделка «`status()` всегда отдаёт `.ready`» эту проверку уже не
    /// пройдёт.
    func test_k32_statusPermissionsReady_reflectsComputation() async {
        let fixture = makeFixture(startingStatus: .granted)
        fixture.permissions.setStatus(.denied, for: .microphone)

        let status = await fixture.facade.status()
        XCTAssertEqual(status.permissionsReady, .notReady)
    }

    /// (б): все обязательные выданы, хотя бы одно `.unknown` — `.unknownUntilFirstUse`.
    func test_k32_vectorB_requiredGrantedExceptUnknown_unknownUntilFirstUse() async {
        let fixture = makeFixture(startingStatus: .granted)
        fixture.permissions.setStatus(.unknown, for: .systemAudioRecording)
        let settings = settingsWith(recordingPolicy: .ask)
        let snapshot = await fixture.permissions.snapshot()
        let readiness = await fixture.facade.permissionsReady(snapshot: snapshot, settings: settings)
        XCTAssertEqual(readiness, .unknownUntilFirstUse)
    }

    /// (в): все обязательные выданы — `.ready`. Необязательные (screenRecording/calendars/
    /// accessibility) намеренно оставлены `.granted` тем же `startingStatus` — их состояние
    /// не должно влиять, что подтверждает сам факт `.ready` при любом их значении.
    func test_k32_vectorC_allRequiredGranted_ready() async {
        let fixture = makeFixture(startingStatus: .granted)
        let settings = settingsWith(recordingPolicy: .ask)
        let snapshot = await fixture.permissions.snapshot()
        let readiness = await fixture.facade.permissionsReady(snapshot: snapshot, settings: settings)
        XCTAssertEqual(readiness, .ready)
    }

    /// (г) (возврат РП п.7): тот же снимок прав, разные настройки — `.notifications` не
    /// обязательно при `.auto`, обязательно и не выдано при `.ask`. Ступени различаются,
    /// хотя ПРАВА не поменялись ни на одно значение — сравнение К33 (шестой вектор,
    /// `EventsTests.swift`) проверяет, что `updateSettings` публикует `statusChanged` именно
    /// на этом переходе; здесь — что сам расчёт правда даёт разные значения.
    func test_k32_vectorD_sameSnapshotDifferentPolicy_differentReadiness() async {
        let fixture = makeFixture(startingStatus: .granted)
        fixture.permissions.setStatus(.denied, for: .notifications)
        let snapshot = await fixture.permissions.snapshot()

        let readinessAuto = await fixture.facade.permissionsReady(
            snapshot: snapshot, settings: settingsWith(recordingPolicy: .auto)
        )
        let readinessAsk = await fixture.facade.permissionsReady(
            snapshot: snapshot, settings: settingsWith(recordingPolicy: .ask)
        )
        XCTAssertEqual(readinessAuto, .ready, "notifications не обязательно вне .ask")
        XCTAssertEqual(readinessAsk, .notReady, "notifications обязательно и denied при .ask")
    }

    private func settingsWith(recordingPolicy: AppSettings.RecordingPolicy) -> AppSettings {
        let defaults = AppSettings.slice1Defaults
        return AppSettings(
            recordingPolicy: recordingPolicy,
            armLeadSeconds: defaults.armLeadSeconds,
            askLeadSeconds: defaults.askLeadSeconds,
            missingSignalGraceSeconds: defaults.missingSignalGraceSeconds,
            silenceStopSeconds: defaults.silenceStopSeconds,
            defaultProfileId: defaults.defaultProfileId,
            processOnACPowerOnly: defaults.processOnACPowerOnly,
            processWhileRecording: defaults.processWhileRecording,
            audioRetentionDays: defaults.audioRetentionDays,
            voiceProfilesEnabled: defaults.voiceProfilesEnabled,
            notifyParticipants: defaults.notifyParticipants,
            launchAtLogin: defaults.launchAtLogin
        )
    }
}
