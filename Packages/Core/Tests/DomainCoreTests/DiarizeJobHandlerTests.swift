//  DiarizeJobHandlerTests — обработчик-пустышка `.diarize` (C-012 v11, IR-145 MEE-469 п. 4):
//  `run` возвращает `.success`, не обращаясь ни к одному порту.
//
//  Место — `Core (Linux)`, способ — Т.

import XCTest
import Foundation
import DomainCore

final class DiarizeJobHandlerTests: XCTestCase {

    func test_typeIsDiarize() {
        XCTAssertEqual(DiarizeJobHandler().type, .diarize)
    }

    func test_runReturnsSuccessWithoutTouchingAnyPort() async {
        // У `DiarizeJobHandler` нет зависимостей: `init()` без параметров — портам взяться
        // неоткуда, поэтому «порты не вызываются» держится по построению.
        let job = Job(
            id: UUID(), type: .diarize,
            payload: .diarize(recordingId: UUID(), profileId: "ru-default"),
            status: .running, priority: 0, attempts: 0, maxAttempts: 3,
            runAfter: Date(timeIntervalSince1970: 0),
            conditions: JobConditions(
                requiresACPower: false, forbidWhileRecording: false,
                maxThermalPressure: .critical, requiresProfileReady: nil
            ),
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        let outcome = await DiarizeJobHandler().run(job, progress: { _ in })
        XCTAssertEqual(outcome, .success)
    }
}
