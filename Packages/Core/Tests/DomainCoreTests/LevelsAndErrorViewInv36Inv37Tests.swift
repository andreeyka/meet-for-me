//  LevelsAndErrorViewInv36Inv37Tests — C-016 v13 (IR-147, MEE-476; задача MEE-477):
//  инв. 36 — уровни захвата только чтением `status()`, `statusChanged` на `levels` нет;
//  инв. 37 — публичный `AppFacadeError.view`, тот же перевод, что `AppEvent.failure`.
//  Векторы (36), (37) абзаца «Ломающие изменения против v12».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class LevelsAndErrorViewInv36Inv37Tests: XCTestCase {

    // MARK: - (36)

    /// Серия `levels` — ни одного `statusChanged`; барьер — смена состава захвата, и
    /// `status()` в нём уже несёт последний уровень.
    func test_36_levelsPublishNothingAndStatusReturnsLast() async throws {
        let fixture = FacadeV11Fixture()
        let recordingId = UUID()
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId, enteredAt: Date())])
        let stream = fixture.facade.events()

        fixture.capture.emit(.started(CaptureStarted(recordingId: recordingId, startedAt: Date(),
                                                     tracks: [], captureGroupKey: "zoom")))
        for level in [Float(0.1), 0.2, 0.7] {
            fixture.capture.emit(.levels(CaptureLevels(mic: level, system: level / 2)))
        }
        fixture.capture.emit(.capturedProcessesChanged(CapturedProcessSnapshot(
            atMs: 0, observedAt: Date(), requestedAppKey: "zoom", resolvedBundleIds: [], processes: [],
            containsUnrequested: false
        )))
        let events = await collectEvents(stream, count: 4, timeoutSeconds: 1)

        XCTAssertEqual(events.count, 1, "statusChanged только от барьера")
        guard case .statusChanged(let published)? = events.first else { return XCTFail("пришло \(events)") }
        XCTAssertEqual(published.activeSession?.micLevel, 0.7)
        let status = await fixture.facade.status()
        XCTAssertEqual(status.activeSession?.micLevel, 0.7)
        XCTAssertEqual(status.activeSession?.systemLevel, 0.35)
    }

    // MARK: - (37)

    private static let allCases: [(AppFacadeError, String)] = [
        (.notFound(entity: "meeting", id: "x"), "notFound"),
        (.notAllowed(reason: "r"), "notAllowed"),
        (.permissionRequired(.microphone), "permissionRequired"),
        (.profileNotReady(profileId: "p", missingModelIds: ["m"]), "profileNotReady"),
        (.settingsUnreadable(key: "k"), "settingsUnreadable"),
        (.jobFailed(jobId: UUID(), type: .transcribe, message: "m"), "jobFailed")
    ]

    /// Каждый случай — `facade.<имя case>`; `permissionKind` только у `permissionRequired`;
    /// `underlying(v)` — `v` как есть.
    func test_37_viewCodeForEveryCase() {
        for (error, name) in Self.allCases {
            XCTAssertEqual(error.view.code, "facade." + name)
            XCTAssertEqual(error.view.permissionKind, name == "permissionRequired" ? .microphone : nil, name)
        }
        let inner = AppErrorView(code: "storage.io", message: "m", recoverySuggestion: "r", permissionKind: .calendars)
        XCTAssertEqual(AppFacadeError.underlying(inner).view, inner)
    }

    /// `AppEvent.failure` для того же значения даёт равный `AppErrorView`.
    func test_37_viewEqualsAsyncFailure() async {
        let inner = AppErrorView(code: "engine.timedOut", message: "m", recoverySuggestion: nil, permissionKind: nil)
        for error in Self.allCases.map(\.0) + [.underlying(inner)] {
            let fixture = FailureFixture()
            let published = await fixture.asyncView(for: error)
            XCTAssertEqual(published, error.view, error.view.code)
        }
    }
}
