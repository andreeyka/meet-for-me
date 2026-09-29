//  ErrorDictionaryEngineFacadeTests — К27 перечня MEE-401 (C-016 v10, §3.1, инв. 21, 23),
//  строки словаря `engine.*` (8 + 9 `engine.engineFailure.*`) и `facade.*` (5), задача
//  MEE-450. Остальные таблицы К27 — `ErrorDictionaryTests.swift` (storage, permissions),
//  `CalendarCommandsTests+ErrorWrapping.swift` (calendar), `RecordingCommandsTests.swift`
//  (capture), `SpeakerAssignmentTests.swift` (attribution); `models.*`/`jobs.*` придут с
//  группами М/Н.
//
//  Обе таблицы проведены асинхронным путём — `publishFailure(_:)` → `events()` →
//  `AppEvent.failure`. Для этих двух источников это и есть путь, которым контракт их
//  доставляет: ни один метод §4 не обращается к `TranscriptionServicePort` (отказ движка —
//  «отвалился движок», §«Поведение»), а `AppFacadeError` синхронно бросается как есть и
//  до словаря доезжает «путём `AppEvent.failure`» (журнал изданий C-016, v2, п. 2).
//
//  Строки строятся правилом `<префикс>.<имя case>` по действующим объявлениям источников:
//  `TranscriptionServiceError` (DomainCore), `AppFacadeError` (DomainCore). Имена случаев
//  `EngineError` (C-011) взяты списком: `EngineError` объявлен в `EngineKit`, а
//  `DomainCoreTests` от него не зависит, и в `DomainCore` он доезжает строкой
//  `engineFailure(code:)` — ровно в том виде, в каком тест его и подаёт.

import XCTest
@testable import DomainCore
import DomainTestKit

final class ErrorDictionaryEngineFacadeTests: XCTestCase {

    private struct Row {
        let error: Error
        let expectedCode: String
        let expectedPermissionKind: PermissionKind?
    }

    /// Имена девяти случаев `EngineError` (C-011) — `<code>` строки `engine.engineFailure.*`.
    private let engineErrorCaseNames = [
        "modelMissing", "modelIncompatible", "audioUnreadable", "unsupportedLanguage",
        "unsupportedRequest", "outOfMemory", "cancelled", "invalidResult", "runtimeFailure"
    ]

    private var engineRows: [Row] {
        let transport: [(TranscriptionServiceError, String)] = [
            (.serviceUnavailable(message: "m"), "serviceUnavailable"),
            (.serviceCrashed, "serviceCrashed"),
            (.protocolVersionMismatch(client: 1, service: 2), "protocolVersionMismatch"),
            (.messageTooLarge(bytes: 1), "messageTooLarge"),
            (.invalidRequest(message: "m"), "invalidRequest"),
            (.modelsNotReady(profileId: "p", message: "m"), "modelsNotReady"),
            (.recordingNotReady(recordingId: UUID(), message: "m"), "recordingNotReady"),
            (.timedOut(seconds: 5), "timedOut"),
            (.cancelled, "cancelled")
        ]
        let transportRows = transport.map {
            Row(error: $0.0, expectedCode: "engine.\($0.1)", expectedPermissionKind: nil)
        }
        let engineFailureRows = engineErrorCaseNames.map { name in
            Row(
                error: TranscriptionServiceError.engineFailure(code: name, message: "m"),
                expectedCode: "engine.engineFailure.\(name)",
                expectedPermissionKind: nil
            )
        }
        return transportRows + engineFailureRows
    }

    private var facadeRows: [Row] {
        [
            Row(
                error: AppFacadeError.notFound(entity: "Meeting", id: "x"),
                expectedCode: "facade.notFound", expectedPermissionKind: nil
            ),
            Row(
                error: AppFacadeError.notAllowed(reason: "r"),
                expectedCode: "facade.notAllowed", expectedPermissionKind: nil
            ),
            Row(
                error: AppFacadeError.permissionRequired(.microphone),
                expectedCode: "facade.permissionRequired", expectedPermissionKind: .microphone
            ),
            Row(
                error: AppFacadeError.profileNotReady(profileId: "p", missingModelIds: ["m"]),
                expectedCode: "facade.profileNotReady", expectedPermissionKind: nil
            ),
            Row(
                error: AppFacadeError.settingsUnreadable(key: "k"),
                expectedCode: "facade.settingsUnreadable", expectedPermissionKind: nil
            ),
            // C-016 v11, инв. 31 (MEE-462): новый случай — тем же правилом `facade.<case>`.
            Row(
                error: AppFacadeError.jobFailed(jobId: UUID(), type: .transcribe, message: "m"),
                expectedCode: "facade.jobFailed", expectedPermissionKind: nil
            )
        ]
    }

    private func assertRows(_ rows: [Row], file: StaticString = #filePath, line: UInt = #line) async {
        for row in rows {
            let fixture = FailureFixture()
            let view = await fixture.asyncView(for: row.error, file: file, line: line)
            XCTAssertEqual(view?.code, row.expectedCode, "\(row.error)", file: file, line: line)
            XCTAssertEqual(view?.permissionKind, row.expectedPermissionKind, "\(row.error)", file: file, line: line)
        }
    }

    /// К27: 18 строк `engine.*` — девять случаев транспорта (с `recordingNotReady`, C-016 v12) и
    /// девять `engine.engineFailure.*`;
    /// колонка `permissionKind` (инв. 23) — `nil` на каждой: ни один отказ не вызван
    /// состоянием системного права.
    func test_k27_engineRows_codeAndPermissionKind() async throws {
        let rows = engineRows
        XCTAssertEqual(rows.count, 18)
        await assertRows(rows)
    }

    /// §3.1, «Три строки…», п. 1: `engine.cancelled` (транспорт) и
    /// `engine.engineFailure.cancelled` (движок) — два разных кода.
    func test_k27_engineCancelledAndEngineFailureCancelledAreDistinct() async throws {
        let fixture = FailureFixture()
        let transport = await fixture.asyncView(for: TranscriptionServiceError.cancelled)
        let engine = await fixture.asyncView(
            for: TranscriptionServiceError.engineFailure(code: "cancelled", message: "m")
        )
        XCTAssertEqual(transport?.code, "engine.cancelled")
        XCTAssertEqual(engine?.code, "engine.engineFailure.cancelled")
        XCTAssertTrue(engine?.code.hasPrefix("engine.engineFailure.") ?? false)
        XCTAssertFalse(transport?.code.hasPrefix("engine.engineFailure.") ?? true)
    }

    /// К63 (дельта `АВ`): две строки словаря v11. (i) `AppFacadeError.jobFailed` — `facade.jobFailed`
    /// по общему правилу. (ii) §3.1, «Три строки…», п. 1 (IR-143): код движка вне перечня
    /// `EngineError` действующего C-011 («сервис новее клиента») — дословно, не `app.internalError`.
    func test_k63_facadeJobFailedAndEngineFailureUnknownCodeRows() async throws {
        let fixture = FailureFixture()
        let jobFailed = await fixture.asyncView(
            for: AppFacadeError.jobFailed(jobId: UUID(), type: .transcribe, message: "x")
        )
        XCTAssertEqual(jobFailed?.code, "facade.jobFailed", "(i)")
        XCTAssertNil(jobFailed?.permissionKind, "(i)")

        XCTAssertFalse(engineErrorCaseNames.contains("futureCode"), "иначе вектор (ii) вакуумен")
        let unknown = await fixture.asyncView(
            for: TranscriptionServiceError.engineFailure(code: "futureCode", message: "x")
        )
        XCTAssertEqual(unknown?.code, "engine.engineFailure.futureCode", "(ii)")
        XCTAssertNil(unknown?.permissionKind, "(ii)")
    }

    /// К27: шесть строк `facade.*` (v11 добавил `jobFailed`); колонка `permissionKind` — у
    /// `facade.permissionRequired` тот `PermissionKind`, что несёт сам случай (§3.1), у остальных `nil`.
    func test_k27_facadeRows_codeAndPermissionKind() async throws {
        let rows = facadeRows
        XCTAssertEqual(rows.count, 6)
        await assertRows(rows)
    }

    /// К27/К30, вторая колонка по признаку, а не по одному вектору: `facade.permissionRequired`
    /// несёт ровно своё право для каждого `PermissionKind.allCases`.
    func test_k27_facadePermissionRequired_carriesItsKindForEveryPermissionKind() async throws {
        let rows = PermissionKind.allCases.map {
            Row(error: AppFacadeError.permissionRequired($0), expectedCode: "facade.permissionRequired",
                expectedPermissionKind: $0)
        }
        await assertRows(rows)
    }
}
