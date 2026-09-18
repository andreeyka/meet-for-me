//  Пробуждение и граница — К68 и К84, плюс перепроверка К9 над выросшей областью.
//  MEE-307, часть C. Пункты плана MEE-288 §3, разделы И и М.
//
//  ТРИ ПУНКТА СТОЯТ НА ПУТЕВОЙ ОБЛАСТИ, КОТОРАЯ ЭТОЙ РАБОТОЙ ВЫРОСЛА: К9, К68 и К84.
//  У К9 и К84 ответ — «ноль» и «ни одного», отрицание монотонное, и краснеть верной частью
//  C им нечем; у К68 ответа-счёта нет вовсе. Но область у них ПУТЕВАЯ, и часть C добавляет
//  в неё три файла — `SessionMachineScheduler.swift`, `SessionMachineRecovery.swift`,
//  `SessionMachineTableRows.swift`, — поэтому все три прогнаны по НАПИСАННОМУ коду, а не
//  по ожидаемому.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineWakeAndBoundaryTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    private struct SourceFile {
        let name: String
        let text: String
    }

    /// Пути машины — та же область, что у К9, К19, К27 и К54: `SessionMachine*.swift` и
    /// `SessionCoordinator.swift`. Часть C добавила в неё три файла, и вектор непустоты
    /// ниже это проверяет счётом, а не верой.
    ///
    /// Чтение области своё, а не общее с `SessionMachineTextTests`, и это не дубль: там оно
    /// `private` по тому же доводу, каким `private` оно и здесь — область есть часть
    /// утверждения пункта, и вынести её в общую оснастку значит дать двум пунктам одно
    /// место, которое правится молча.
    private func machineSources() throws -> [SourceFile] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DomainCore")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .filter { $0.hasPrefix("SessionMachine") || $0 == "SessionCoordinator.swift" }
            .sorted()
        XCTAssertFalse(names.isEmpty, "в области путей машины не найдено ни одного файла")
        return try names.map {
            SourceFile(
                name: $0,
                text: try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
            )
        }
    }

    // MARK: - К68 (§9.3, `didWake`)

    /// `PowerEvent.didWake` после сна, за время которого прошли `armAt`, `e.start`,
    /// `graceEndsAt` нескольких сессий. Машина зовёт `reschedule(now:)`, и СРОКИ,
    /// ПРОЙДЕННЫЕ ВО СНЕ, ИСПОЛНЯЮТСЯ ПЕРВЫМ `tick` ПОСЛЕ ПРОБУЖДЕНИЯ — это инвариант 14
    /// дословно (К11), отдельного правила для сна нет.
    func test_k68_deadlinesPassedInSleepAreExecutedByTheFirstTickAfterWaking() async throws {
        let stand = try bench()
        let settings = SessionMachineFixtures.settings()
        let first = try SessionMachineFixtures.event()
        let second = try SessionMachineFixtures.event(start: moment.addingTimeInterval(600))
        stand.seed(first)
        stand.seed(second)

        let before = SessionMachineRules.arm(for: first, settings: settings)
            .armAt.addingTimeInterval(-60)
        await stand.machine.start(now: before)
        await stand.machine.tick(now: before)
        let asleep = await stand.machine.sessions()
        XCTAssertEqual(asleep.count, 2, "оснастка: обе сессии заведены до сна")
        XCTAssertEqual(
            Set(asleep.map(\.state)), [.scheduled], "и обе стоят в `scheduled`"
        )

        // Сон: `armAt`, `e.start` и `graceEndsAt` обеих встреч остались позади.
        let woke = SessionMachineRules.arm(for: second, settings: settings)
            .graceEndsAt.addingTimeInterval(1)
        await stand.deliver(PowerEvent.didWake)
        await stand.machine.tick(now: woke)

        let after = await stand.machine.sessions()
        XCTAssertTrue(
            after.isEmpty,
            "все сроки, пройденные во сне, исполнены ПЕРВЫМ `tick`, а не по одному на `tick`"
        )
        XCTAssertEqual(
            Set(stand.meetings.storedRecords.map(\.status)), [.skipped],
            "и обе встречи ушли в `skipped` своими сроками"
        )
        await stand.machine.stop()
    }

    /// `didWake` зовёт `reschedule(now:)`, и наблюдается это чтением хранилища: `reschedule`
    /// читает встречи заново, потому что сроки нигде не хранятся — они функция от события и
    /// настроек (§9.2).
    func test_k68_didWakeCallsReschedule() async throws {
        let stand = try bench()
        stand.seed(try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600)))
        await stand.machine.start(now: moment)
        await stand.machine.tick(now: moment)
        let before = stand.log.count(port: "MeetingRepository", method: "meetings(from:to:)")

        await stand.deliver(PowerEvent.didWake)
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let after = stand.log.count(port: "MeetingRepository", method: "meetings(from:to:)")

        XCTAssertGreaterThan(
            after, before + 1,
            "`didWake` добавил чтение хранилища сверх того, которое делает сам `tick`"
        )
        await stand.machine.stop()
    }

    /// `willSleep` записи не останавливает и состояния не меняет (§9.3, К69): второго
    /// механизма для сна нет ни одного.
    func test_k68_willSleepChangesNothing() async throws {
        let stand = try bench()
        stand.allowCaptureStart()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        await stand.machine.start(now: moment.addingTimeInterval(-60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-60), provider: "zoom"
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(-60))
        let recording = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(recording.state, .recording, "оснастка: запись идёт")

        await stand.deliver(PowerEvent.willSleep)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment, provider: "zoom"
        ))
        await stand.machine.tick(now: moment)

        let after = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(after.state, .recording, "`willSleep` записи не останавливает")
        XCTAssertEqual(after.recordingId, recording.recordingId)
        XCTAssertEqual(
            stand.log.count(port: "AudioCapturePort", method: "stop()"), 0, "`stop()` не зван"
        )
        await stand.machine.stop()
    }

    // MARK: - К84 («Данные на границе», «Чего на границе нет»; §10, перечень А)

    /// Ни одного файлового пути и ни одного `URL` на границе, КРОМЕ `CaptureRequest
    /// .directory`, который машина получает от хранилища и передаёт в захват НЕ РАЗБИРАЯ.
    /// Область путевая и ВЫРОСЛА частью C — прогон идёт по написанному коду.
    func test_k84_theOnlyUrlOnTheBoundaryIsTheCaptureDirectory() throws {
        let sources = try machineSources()
        XCTAssertGreaterThanOrEqual(sources.count, 12, "вектор непустоты: область не пуста и выросла")
        XCTAssertTrue(
            sources.contains { $0.name == "SessionMachineScheduler.swift" }
                && sources.contains { $0.name == "SessionMachineRecovery.swift" },
            "и файлы части C в неё входят"
        )

        for source in sources {
            for line in source.text.components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                XCTAssertFalse(
                    code.contains("FileManager"), "\(source.name): машина файлов не трогает"
                )
                XCTAssertFalse(
                    code.contains("appendingPathComponent"),
                    "\(source.name): каталог не склеивается — он приходит готовым"
                )
                XCTAssertFalse(
                    code.contains("URL(fileURLWithPath"),
                    "\(source.name): своего `URL` машина не строит ни одного"
                )
            }
        }
    }

    /// Восемь значимых значений уходят наружу, и восьмое — `RecordingRecord` в хранилище
    /// через `RecordingRepository.save(_:)`, приведение `RecordingStatus` восстановительным
    /// входом (§10, перечень А, издание v4). Наблюдается прогоном, а не чтением.
    func test_k84_theEighthOutwardValueIsTheRecordingRecordOfListA() async throws {
        let stand = try bench()
        let recordingId = UUID()
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: nil)
        stand.repositories.recordings.seed([RecordingRecord(manifest: manifest, status: .recording)])
        stand.capture.setRecoverManifest(manifest)

        await stand.machine.start(now: moment)

        XCTAssertEqual(
            stand.log.count(port: "RecordingRepository", method: "save(_:)"), 1,
            "`RecordingRecord` ушёл наружу ровно раз — приведением статуса перечнем А"
        )
        XCTAssertEqual(
            stand.repositories.recordings.storedRecords.first?.status, .finalized,
            "и ушло именно приведение к фактическому состоянию"
        )
        await stand.machine.stop()
    }

    /// `CaptureRequest.directory` приходит от хранилища и уходит в захват НЕ РАЗБИРАЯ: тот
    /// же `URL`, что отдала функция каталога, поле в поле.
    func test_k84_theCaptureDirectoryPassesThroughUnparsed() async throws {
        let stand = try bench()
        stand.allowCaptureStart()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        await stand.machine.start(now: moment.addingTimeInterval(-60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-60), provider: "zoom"
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(-60))

        let request = try unwrap(stand.capture.recordedCalls.compactMap { call -> CaptureRequest? in
            guard case let .start(request) = call else { return nil }
            return request
        }.first)
        XCTAssertEqual(
            request.directory, SessionMachineFixtures.recordingDirectory(request.recordingId),
            "каталог передан не разбирая: ни склейки, ни проверки существования"
        )
        await stand.machine.stop()
    }

    // MARK: - К9 (§4), перепроверка над выросшей областью

    /// Ноль вхождений собственных часов и таймеров на путях `SessionCoordinator` И
    /// `Scheduler`. Пункт перепроверяется здесь потому, что часть C добавила в область три
    /// файла, а его область — путевая; `SessionMachineTextTests` проверяет то же на своей
    /// половине, и два места здесь не спорят, а меряют одну и ту же область с разных сторон.
    func test_k9_theSchedulerBringsNoClockOfItsOwn() throws {
        let forbidden = [
            "Date()", "Date.now", "Timer", "asyncAfter", "DispatchSourceTimer",
            "Task.sleep", "ContinuousClock", "SuspendingClock",
            "CFAbsoluteTimeGetCurrent", "mach_absolute_time"
        ]
        let sources = try machineSources()
            .filter { $0.name.contains("Scheduler") || $0.name.contains("Recovery") }
        XCTAssertEqual(sources.count, 2, "вектор непустоты: оба файла части C на месте")
        for source in sources {
            for needle in forbidden {
                XCTAssertFalse(
                    source.text.contains(needle), "\(source.name): «\(needle)» не встречается"
                )
            }
        }
    }
}
