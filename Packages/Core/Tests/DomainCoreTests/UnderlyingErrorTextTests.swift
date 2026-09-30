//  UnderlyingErrorTextTests — тексты для человека в `underlying` и в `facade.jobFailed` (C-016 v13,
//  §3.1 и инв. 37; MEE-494). По §3.1 `message` на равенство не проверяется — проверяется форма: нет
//  имени случая и скобок Swift. `code` не меняется — его проверяют тесты словаря (`ErrorDictionary*`).
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен

import XCTest
@testable import DomainCore
import DomainTestKit

final class UnderlyingErrorTextTests: XCTestCase {

    private static let source = CalendarSourceId(rawValue: "eventkit")

    /// Каждый случай каждого источника со словарём §3.1, который фасад сводит в `underlying`.
    private static var allErrors: [Error] {
        let storage: [Error] = [
            StorageError.notFound(entity: "Recording", id: UUID().uuidString),
            StorageError.constraintViolation(message: "UNIQUE failed"),
            StorageError.migrationFailed(identifier: "v7", message: "no such column"),
            StorageError.fileMissing(path: "/tmp/a.caf"),
            StorageError.dataCorrupted(entity: "Job", id: "x", message: "bad json"),
            StorageError.io(message: "disk I/O error")
        ]
        let calendar: [Error] = [
            CalendarError.notConfigured(sourceId: source), CalendarError.authorizationRequired(sourceId: source),
            CalendarError.transport(sourceId: source, message: "offline"),
            CalendarError.protocolViolation(sourceId: source, message: "schema"),
            CalendarError.timeout(sourceId: source, seconds: 30), CalendarError.cancelled
        ]
        let attribution: [Error] = [
            AttributionError.unknownTranscript(UUID()), AttributionError.unknownCluster(3),
            AttributionError.unknownPerson(UUID()),
            AttributionError.embeddingModelMismatch(expected: "ecapa-1", actual: "ecapa-2"),
            AttributionError.segmentIdsMismatch(expected: 3, actual: 4), AttributionError.voiceProfilesDisabled
        ]
        let permissions: [Error] = [
            PermissionsError.loginItemRegistrationFailed(message: "denied"),
            PermissionsError.settingsPaneUnavailable(kind: .microphone)
        ]
        let jobs: [Error] = [
            JobQueueError.unknownJob(UUID()), JobQueueError.invalidPriority(99),
            JobQueueError.handlerAlreadyRegistered(.transcribe)
        ]
        return storage + calendar + attribution + permissions + jobs + engineErrors + modelErrors + captureErrors
    }

    private static var engineErrors: [Error] {
        let simple: [TranscriptionServiceError] = [
            .serviceUnavailable(message: "xpc"), .serviceCrashed,
            .protocolVersionMismatch(client: 1, service: 2), .messageTooLarge(bytes: 1_000),
            .invalidRequest(message: "bad"), .modelsNotReady(profileId: "p1", message: "missing"),
            .recordingNotReady(recordingId: UUID(), message: "not finalized"), .timedOut(seconds: 60), .cancelled
        ]
        let engineCodes = [
            "modelMissing", "modelIncompatible", "audioUnreadable", "unsupportedLanguage", "unsupportedRequest",
            "outOfMemory", "cancelled", "invalidResult", "runtimeFailure", "brandNewCode"
        ]
        return simple + engineCodes.map { TranscriptionServiceError.engineFailure(code: $0, message: "raw") }
    }

    private static var modelErrors: [Error] {
        let errors: [ModelCatalogError] = [
            .manifestInvalid(message: "json"), .manifestUnreachable(message: "dns"),
            .unknownModel(id: "m1", version: "1"), .unknownProfile(id: "p1"),
            .notDownloaded(modelId: "m1", version: "1"),
            .checksumMismatch(fileName: "f", expected: "a", actual: "b"), .downloadFailed(message: "503"),
            .insufficientDiskSpace(requiredBytes: 2_000_000_000, availableBytes: 1_000),
            .unsupportedChip(required: .m2), .insufficientRAM(requiredGB: 16),
            .modelInUseByProfile(modelId: "m1", profileIds: ["p1", "p2"]), .modelInUse(modelId: "m1", version: "1"),
            .userProfilesUnreadable(message: "bad"), .builtInProfileImmutable(id: "p1"), .cancelled
        ]
        return errors
    }

    private static var captureErrors: [Error] {
        let errors: [CaptureError] = [
            .alreadyRunning, .notRunning, .nothingToCapture, .systemAudioDenied,
            .systemAudioPromptTimedOut(waitedSeconds: 30), .microphoneDenied,
            .microphonePromptTimedOut(waitedSeconds: 30), .inputDeviceUnavailable(uid: "BuiltIn"),
            .directoryUnusable(message: "ro"), .systemUnavailable(message: "hal"),
            .recoveryFailed(directoryName: "d", message: "m")
        ]
        return errors
    }

    /// Имя случая — то, что §3.1 кладёт в код: всё до первой скобки описания значения.
    private func caseName(_ error: Error) -> String {
        let description = String(describing: error)
        return description.split(separator: "(", maxSplits: 1).first.map(String.init) ?? description
    }

    /// Синхронный и асинхронный пути сводят ошибку одним `errorView(for:)` (инв. 24).
    func test_underlyingMessageIsHumanTextForEveryCase() async {
        let facade = FacadeV11Fixture().facade
        for error in Self.allErrors {
            let name = caseName(error)
            let view = await facade.errorView(for: error)
            XCTAssertFalse(view.message.isEmpty, view.code)
            XCTAssertFalse(view.message.contains(name), "\(view.code): «\(view.message)»")
            XCTAssertFalse(view.message.contains("("), "\(view.code): «\(view.message)»")
            XCTAssertFalse(view.message.contains(")"), "\(view.code): «\(view.message)»")
            if case .engineFailure(let code, _)? = error as? TranscriptionServiceError {
                XCTAssertFalse(view.message.contains(code), "\(view.code): «\(view.message)»")
            }
            if let suggestion = view.recoverySuggestion {
                XCTAssertFalse(suggestion.contains(name), "\(view.code): «\(suggestion)»")
                XCTAssertFalse(suggestion.contains("("), "\(view.code): «\(suggestion)»")
            }
        }
    }

    /// Код не изменился: тот же, что по правилу §3.1 (`<префикс>.<имя case>`).
    func test_codeStaysByRule() async {
        let facade = FacadeV11Fixture().facade
        let view = await facade.errorView(for: StorageError.io(message: "x"))
        XCTAssertEqual(view.code, "storage.io")
        let outOfMemory = TranscriptionServiceError.engineFailure(code: "outOfMemory", message: "")
        let engine = await facade.errorView(for: outOfMemory)
        XCTAssertEqual(engine.code, "engine.engineFailure.outOfMemory")
    }

    private struct UnlistedError: Error, CustomStringConvertible {
        var description: String { "UnlistedError: ошибка вне словаря" }
    }

    /// `app.internalError`: человеческая фраза плюс описание исходной ошибки (§3.1, «всё прочее»).
    func test_internalErrorHasHumanHeadAndDetail() async {
        let view = await FacadeV11Fixture().facade.errorView(for: UnlistedError())
        XCTAssertEqual(view.code, "app.internalError")
        XCTAssertTrue(view.message.hasPrefix("Внутренняя ошибка приложения"), view.message)
        XCTAssertTrue(view.message.contains("ошибка вне словаря"), view.message)
        XCTAssertFalse(view.recoverySuggestion?.isEmpty ?? true)
    }

    // MARK: - facade.jobFailed

    private struct JobFailureRow {
        let raw: String
        /// Имя случая или код, которых в показе быть не должно.
        let name: String
        /// Кусок подробности (строчными); `nil` — подробности нет, в показе только заголовок.
        let detail: String?
    }

    /// Строки прежних изданий обработчиков (описания значений Swift) и «interrupted» очереди.
    private static let swiftDescriptionRows: [JobFailureRow] = [
        JobFailureRow(raw: "serviceCrashed", name: "serviceCrashed", detail: "аварийно завершилась"),
        JobFailureRow(raw: "timedOut(30)", name: "timedOut", detail: "не ответила вовремя"),
        JobFailureRow(
            raw: "protocolVersionMismatch(client: 1, service: 2)", name: "protocolVersionMismatch",
            detail: "версии приложения и службы"
        ),
        JobFailureRow(raw: "messageTooLarge(1000)", name: "messageTooLarge", detail: "слишком велик"),
        JobFailureRow(raw: "save: io(message: \"disk full\")", name: "io", detail: "записать данные на диск"),
        JobFailureRow(raw: "io(message: \"disk full\")", name: "io", detail: "записать данные на диск"),
        JobFailureRow(raw: "notFound(entity: \"Recording\", id: \"x\")", name: "notFound", detail: "данные не найдены"),
        JobFailureRow(raw: "voiceProfilesDisabled", name: "voiceProfilesDisabled", detail: "профили выключены"),
        JobFailureRow(
            raw: "segmentIdsMismatch(expected: 3, actual: 4)", name: "segmentIdsMismatch",
            detail: "транскрипт изменился"
        ),
        JobFailureRow(raw: "settingsUnreadable(key: \"k\")", name: "settingsUnreadable", detail: "прочитать настройку"),
        JobFailureRow(
            raw: "underlying(DomainCore.AppErrorView(code: \"storage.io\", message: \"m\"))", name: "underlying",
            detail: nil
        ),
        JobFailureRow(raw: "interrupted", name: "interrupted", detail: "приложение закрылось"),
        JobFailureRow(raw: "somethingNew(x: 1)", name: "somethingNew", detail: nil),
        JobFailureRow(raw: "brandNewCase", name: "brandNewCase", detail: nil),
        JobFailureRow(
            raw: "Failed: DecodingError.keyNotFound(CodingKeys(stringValue: \"a\"))", name: "DecodingError", detail: nil
        )
    ]

    /// Коды §3.1, которые пишут обработчики с MEE-498.
    private static let codeRows: [JobFailureRow] = [
        JobFailureRow(raw: "storage.io", name: "storage", detail: "записать данные на диск"),
        JobFailureRow(raw: "storage.dataCorrupted", name: "storage", detail: "повреждены"),
        JobFailureRow(raw: "app.internalError", name: "internalError", detail: "внутренняя ошибка приложения"),
        JobFailureRow(
            raw: "engine.engineFailure.codeFromNewerService", name: "codeFromNewerService", detail: "сбой движка"
        ),
        JobFailureRow(raw: "attribution.unknownPerson", name: "unknownPerson", detail: "человек не найден"),
        JobFailureRow(raw: "facade.settingsUnreadable", name: "settingsUnreadable", detail: "прочитать настройку"),
        JobFailureRow(raw: "facade.notAllowed", name: "notAllowed", detail: "не удалось выполнить действие")
    ]

    /// Строки, которые обработчики задач кладут в `JobEvent.failed(error:)`: описания значений
    /// Swift, код §3.1, «interrupted» очереди. В `message` показа — ни имени случая, ни скобок, и
    /// подробность та, что ждётся (MEE-498: проверка не только отрицательная).
    func test_jobFailedMessageHasNoSwiftDescription() {
        for row in Self.swiftDescriptionRows + Self.codeRows {
            let event = JobEvent.failed(jobId: UUID(), type: .transcribe, error: row.raw, willRetry: false)
            guard let error = AppFacadeImpl.jobFailedError(for: event) else { return XCTFail(row.raw) }
            guard case .jobFailed(_, _, let message) = error else { return XCTFail(row.raw) }
            XCTAssertEqual(message, row.raw, "значение случая — строка очереди дословно (инв. 31)")
            let view = error.view
            XCTAssertEqual(view.code, "facade.jobFailed")
            XCTAssertFalse(view.message.contains(row.name), "\(row.raw): «\(view.message)»")
            XCTAssertFalse(view.message.contains("("), "\(row.raw): «\(view.message)»")
            XCTAssertFalse(view.message.contains(")"), "\(row.raw): «\(view.message)»")
            let head = "Транскрибация не выполнена"
            if let detail = row.detail {
                XCTAssertTrue(view.message.hasPrefix(head + ": "), "\(row.raw): «\(view.message)»")
                XCTAssertTrue(view.message.contains(detail), "\(row.raw): «\(view.message)»")
            } else {
                XCTAssertEqual(view.message, head, "\(row.raw): подробности нет")
            }
        }
    }

    /// Свободный текст движка — однословный (`"oom"`) и с точкой (`"cuda.oom"`) — и тексты для
    /// человека из обработчиков показываются как есть (MEE-498).
    func test_jobFailedKeepsFreeEngineTextAndHandlerTexts() {
        let texts = [
            "oom", "cuda.oom", "save: oom", UnderlyingErrorText.wrongPayloadText,
            TranscribeJobHandler.cancelledWithoutRequestText, "Транскрипт не найден — возможно, он уже удалён"
        ]
        for raw in texts {
            let view = AppFacadeError.jobFailed(jobId: UUID(), type: .transcribe, message: raw).view
            let shown = raw == "save: oom" ? "oom" : raw
            XCTAssertTrue(view.message.hasSuffix(": \(shown)"), "\(raw): «\(view.message)»")
        }
    }

    /// Текст обработчика или движка без описания значения Swift показывается как есть.
    func test_jobFailedKeepsHumanDetail() {
        let view = AppFacadeError.jobFailed(jobId: UUID(), type: .diarize, message: "Model file not found").view
        XCTAssertTrue(view.message.hasSuffix(": Model file not found"), view.message)
        let known = AppFacadeError.jobFailed(jobId: UUID(), type: .transcribe, message: "serviceCrashed").view
        XCTAssertTrue(known.message.contains("служба распознавания"), known.message)
    }
}
