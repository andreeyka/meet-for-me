//  FacadeErrorViewTextTests — человеческие тексты `AppFacadeError.view` (C-016 v13, §3.1 и инв. 37;
//  MEE-492). По §3.1 `message` и `recoverySuggestion` на равенство не проверяются — проверяется
//  форма: в тексте нет имени случая и скобок Swift, у `permissionRequired` есть совет. Код (`code`)
//  проверяет `LevelsAndErrorViewInv36Inv37Tests`, здесь он не трогается.
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class FacadeErrorViewTextTests: XCTestCase {

    /// Каждый случай, кроме `underlying`; `permissionRequired` — со всеми шестью правами.
    private static var allCases: [(AppFacadeError, String)] {
        var cases: [(AppFacadeError, String)] = [
            (.notFound(entity: "Meeting", id: UUID().uuidString), "notFound"),
            (.notFound(entity: "Recording", id: UUID().uuidString), "notFound"),
            (.notFound(entity: "meeting", id: "x"), "notFound"),
            (.notFound(entity: "НеизвестнаяСущность", id: "x"), "notFound"),
            (.notAllowed(reason: "Эта запись уже завершена"), "notAllowed"),
            (.profileNotReady(profileId: "p", missingModelIds: ["m1", "m2"]), "profileNotReady"),
            (.profileNotReady(profileId: "p", missingModelIds: []), "profileNotReady"),
            (.settingsUnreadable(key: "k"), "settingsUnreadable"),
            (.jobFailed(jobId: UUID(), type: .transcribe, message: "движок не ответил"), "jobFailed"),
            (.jobFailed(jobId: UUID(), type: .transcode, message: ""), "jobFailed")
        ]
        cases += PermissionKind.allCases.map { (.permissionRequired($0), "permissionRequired") }
        return cases
    }

    /// `message` не пуст и не содержит ни имени случая, ни скобок, ни UUID (MEE-492, п. A).
    func test_messageIsHumanTextForEveryCase() {
        for (error, name) in Self.allCases {
            let view = error.view
            XCTAssertFalse(view.message.isEmpty, name)
            XCTAssertFalse(view.message.contains(name), "\(name): «\(view.message)»")
            XCTAssertFalse(view.message.contains("("), "\(name): «\(view.message)»")
            XCTAssertFalse(view.message.contains(")"), "\(name): «\(view.message)»")
            if case .notFound(_, let id) = error {
                XCTAssertFalse(view.message.contains(id), "идентификатор пользователю не показывается")
            }
            if let suggestion = view.recoverySuggestion {
                XCTAssertFalse(suggestion.contains(name), "\(name): «\(suggestion)»")
                XCTAssertFalse(suggestion.contains("("), "\(name): «\(suggestion)»")
            }
        }
    }

    /// `permissionRequired` — совет не пуст для каждого права.
    func test_permissionRequiredHasRecoverySuggestion() {
        for kind in PermissionKind.allCases {
            let suggestion = AppFacadeError.permissionRequired(kind).view.recoverySuggestion
            XCTAssertFalse(suggestion?.isEmpty ?? true, "\(kind)")
        }
    }

    /// `notAllowed` — `reason` и есть текст; `jobFailed` несёт текст отказа очереди (инв. 31).
    func test_reasonAndJobFailureTextReachMessage() {
        XCTAssertEqual(AppFacadeError.notAllowed(reason: "Нельзя").view.message, "Нельзя")
        let failed = AppFacadeError.jobFailed(jobId: UUID(), type: .transcribe, message: "движок не ответил").view
        XCTAssertTrue(failed.message.hasSuffix("движок не ответил"), failed.message)
    }

    /// Отказы команд, которые фасад бросает сам, — без имени метода и идентификатора (MEE-492):
    /// `retryJob` из недопустимого статуса.
    func test_retryJobReasonHasNoMethodPrefix() async throws {
        let fixture = FacadeV11Fixture()
        let jobId = UUID()
        let epoch = Date(timeIntervalSince1970: 0)
        fixture.jobQueue.setJobs([Job(
            id: jobId, type: .transcribe,
            payload: .transcribe(recordingId: UUID(), profileId: "p1", language: nil),
            status: .running, priority: 30, attempts: 1, maxAttempts: 3, runAfter: epoch,
            conditions: JobConditions(requiresACPower: false, forbidWhileRecording: true,
                                      maxThermalPressure: .fair, requiresProfileReady: "p1"),
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: epoch,
            lastError: nil, createdAt: epoch, updatedAt: epoch
        )])

        do {
            _ = try await fixture.facade.retryJob(id: jobId)
            XCTFail("повтор ожидающей задачи обязан бросить")
        } catch AppFacadeError.notAllowed(let reason) {
            XCTAssertFalse(reason.contains("retryJob"), reason)
            XCTAssertFalse(reason.contains(jobId.uuidString), reason)
            XCTAssertFalse(reason.isEmpty)
        }
    }
}
