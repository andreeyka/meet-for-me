//  FacadeInitAndSyncAsyncTests — дельта `АВ` перечня MEE-401 (`f89d2865`), задача MEE-462:
//  К62 (очередь — обязательная зависимость фасада, IR-144) и К29 в новой форме (инв. 24 на
//  источнике инв. 31 (2): одна и та же `CaptureError` синхронным и асинхронным путём).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class FacadeInitAndSyncAsyncTests: XCTestCase {

    // MARK: - К62 (инв. 31, IR-144): режима «фасад без очереди» нет

    private static var domainCoreSources: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Sources").appendingPathComponent("DomainCore")
    }

    /// Мех.: `jobQueue` в `init` и в хранимом свойстве — не опциональный и без умолчания; ветки
    /// отказа «очередь не передана» в исходнике `DomainCore` нет. Что фасад без очереди не
    /// построить, держит компиляция: каждый вызов `init` в тестах передаёт очередь.
    func test_k62_jobQueueIsRequiredAndNoWithoutQueueBranchExists() throws {
        let facade = try String(
            contentsOf: Self.domainCoreSources.appendingPathComponent("AppFacadeImpl.swift"), encoding: .utf8
        )
        let lines = facade.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains("jobQueue: JobQueue,"), "параметр init — `jobQueue: JobQueue,`")
        XCTAssertTrue(lines.contains("let jobQueue: JobQueue"), "хранимое свойство не опциональное")
        XCTAssertFalse(facade.contains("JobQueue?"), "ни опциональности, ни умолчания `= nil`")

        let files = try FileManager.default.contentsOfDirectory(
            at: Self.domainCoreSources, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("AppFacadeImpl") }
        XCTAssertFalse(files.isEmpty)
        let forbidden = ["require" + "JobQueue", "фасаду не " + "передана"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in forbidden {
                XCTAssertFalse(text.contains(needle), "\(file.lastPathComponent): «\(needle)»")
            }
        }
    }

    // MARK: - К29 (инв. 24; инв. 31, источник (2))

    /// Одна и та же `CaptureError`: синхронно — отказ `startRecording` (машина сессии отдаёт
    /// отказ `AudioCapturePort.start()` как `SessionError.capture`), асинхронно — `.failed` в
    /// потоке захвата. `code` на обоих путях — `capture.<имя case>` дословно.
    func test_k29_sameCaptureErrorGivesSameCodeOnSyncAndAsyncPaths() async throws {
        let cases: [(CaptureError, String)] = [
            (.systemUnavailable(message: "HAL"), "capture.systemUnavailable"),
            (.microphoneDenied, "capture.microphoneDenied"),
            (.directoryUnusable(message: "ro"), "capture.directoryUnusable")
        ]
        for (error, expectedCode) in cases {
            let fixture = FacadeV11Fixture()
            fixture.coordinator.failStartRecording(with: .capture(error))
            var syncView: AppErrorView?
            do {
                _ = try await fixture.facade.startRecording(meetingId: nil)
                XCTFail("\(error): синхронный путь обязан бросить")
            } catch AppFacadeError.underlying(let view) {
                syncView = view
            }

            // Асинхронная ветка К29 — «при идущей записи»: сессия в `recording`, захват стартовал.
            let recordingId = UUID()
            fixture.coordinator.setSessions([recordingSession(recordingId: recordingId, enteredAt: Date())])
            let stream = fixture.facade.events()
            fixture.capture.emit(.started(CaptureStarted(recordingId: recordingId, startedAt: Date(),
                                                         tracks: [], captureGroupKey: "zoom")))
            fixture.capture.emit(.failed(error))
            let events = await collectEvents(stream, count: 1)
            guard case .failure(let asyncView)? = events.first else {
                return XCTFail("\(error): ожидался .failure, пришло \(events)")
            }

            XCTAssertEqual(syncView?.code, expectedCode, "\(error): синхронный путь")
            XCTAssertEqual(asyncView.code, syncView?.code, "\(error): по логам путь не различить")
        }
    }
}
