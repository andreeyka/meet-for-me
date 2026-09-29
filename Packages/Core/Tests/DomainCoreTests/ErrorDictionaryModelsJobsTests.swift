//  ErrorDictionaryModelsJobsTests — К26, К27, К29 перечня MEE-401 (C-016 v10, §3.1, инв. 19,
//  21, 23, 24) для источников групп М и Н: `ModelCatalogError` (`models.*`, 13 строк) и
//  `JobQueueError` (`jobs.*`, 3 строки). Задача MEE-420.
//
//  Каждая строка проведена ОБОИМИ путями, тем же приёмом, что `FailureEventTests`
//  (MEE-450, #183): синхронно — команда фасада (`downloadModel` для каталога, `cancelJob`
//  для очереди) бросает `AppFacadeError.underlying`; асинхронно — `publishFailure(_:)` →
//  `events()` → `AppEvent.failure`. Оба `AppErrorView` строит производственный код; тест
//  сверяет их с кодом, построенным правилом `<префикс>.<имя case>`, и друг с другом (инв. 24).

import XCTest
@testable import DomainCore
import DomainTestKit

final class ErrorDictionaryModelsJobsTests: XCTestCase {

    private struct Row {
        let error: Error
        let caseName: String
    }

    /// Все тринадцать случаев `ModelCatalogError` (C-014 §4) с именем случая — правило §3.1.
    private let modelRows: [(ModelCatalogError, String)] = [
        (.manifestInvalid(message: "m"), "manifestInvalid"),
        (.manifestUnreachable(message: "m"), "manifestUnreachable"),
        (.unknownModel(id: "a", version: "1"), "unknownModel"),
        (.unknownProfile(id: "p"), "unknownProfile"),
        (.notDownloaded(modelId: "a", version: "1"), "notDownloaded"),
        (.checksumMismatch(fileName: "f", expected: "e", actual: "x"), "checksumMismatch"),
        (.downloadFailed(message: "m (скобки в тексте)"), "downloadFailed"),
        (.insufficientDiskSpace(requiredBytes: 2, availableBytes: 1), "insufficientDiskSpace"),
        (.unsupportedChip(required: .m4), "unsupportedChip"),
        (.insufficientRAM(requiredGB: 8), "insufficientRAM"),
        (.modelInUseByProfile(modelId: "a", profileIds: ["p"]), "modelInUseByProfile"),
        (.builtInProfileImmutable(id: "p"), "builtInProfileImmutable"),
        (.cancelled, "cancelled")
    ]

    /// Все три случая `JobQueueError` (C-013).
    private let jobRows: [(JobQueueError, String)] = [
        (.unknownJob(UUID()), "unknownJob"),
        (.invalidPriority(500), "invalidPriority"),
        (.handlerAlreadyRegistered(.transcribe), "handlerAlreadyRegistered")
    ]

    private func asyncView(_ fixture: ModelJobFixture, _ error: Error) async -> AppErrorView? {
        let stream = fixture.facade.events()
        await fixture.facade.publishFailure(error)
        let events = await collectEvents(stream, count: 1)
        guard case .failure(let view)? = events.first else {
            XCTFail("ожидалось .failure, пришло \(events)")
            return nil
        }
        return view
    }

    /// К27 + К26 + К29 для `models.*`: синхронно через `downloadModel`, асинхронно через
    /// `AppEvent.failure`; код — правилом, `permissionKind` — `nil`, пути совпадают.
    func test_k27_modelsRows_syncAndAsyncGiveRuleCode() async throws {
        XCTAssertEqual(modelRows.count, 13)
        for (error, name) in modelRows {
            let fixture = ModelJobFixture()
            fixture.catalog.failDownload(error, forId: "m", version: "1")
            let syncView = await underlyingView { try await fixture.facade.downloadModel(id: "m", version: "1") }
            let asyncView = await asyncView(fixture, error)
            XCTAssertEqual(syncView?.code, "models.\(name)", "\(error)")
            XCTAssertNil(syncView?.permissionKind, "\(error)")
            XCTAssertEqual(asyncView?.code, syncView?.code, "инв. 24: \(error)")
            XCTAssertEqual(asyncView?.permissionKind, syncView?.permissionKind, "\(error)")
        }
    }

    /// К27 + К26 + К29 для `jobs.*`: синхронно через `cancelJob`, асинхронно через `AppEvent.failure`.
    func test_k27_jobsRows_syncAndAsyncGiveRuleCode() async throws {
        XCTAssertEqual(jobRows.count, 3)
        for (error, name) in jobRows {
            let fixture = ModelJobFixture()
            fixture.queue.failCancel(with: error)
            let syncView = await underlyingView { try await fixture.facade.cancelJob(id: UUID()) }
            let asyncView = await asyncView(fixture, error)
            XCTAssertEqual(syncView?.code, "jobs.\(name)", "\(error)")
            XCTAssertNil(syncView?.permissionKind, "\(error)")
            XCTAssertEqual(asyncView?.code, syncView?.code, "инв. 24: \(error)")
            XCTAssertEqual(asyncView?.permissionKind, syncView?.permissionKind, "\(error)")
        }
    }

    /// К26: исходный тип не выходит ни одним полем — наружу `AppFacadeError.underlying`
    /// с `AppErrorView`, а не `ModelCatalogError`/`JobQueueError`.
    func test_k26_catalogAndQueueErrorsDoNotLeakSourceType() async throws {
        let fixture = ModelJobFixture()
        fixture.catalog.failDownload(.cancelled, forId: "m", version: "1")
        fixture.queue.failCancel(with: .invalidPriority(1))
        let calls: [() async throws -> Void] = [
            { try await fixture.facade.downloadModel(id: "m", version: "1") },
            { try await fixture.facade.cancelJob(id: UUID()) }
        ]
        for call in calls {
            do {
                try await call()
                XCTFail("ожидался отказ")
            } catch let error as AppFacadeError {
                guard case .underlying = error else { return XCTFail("ожидался underlying, получено \(error)") }
            } catch {
                XCTFail("наружу вышел тип нижнего слоя: \(type(of: error))")
            }
        }
    }
}
