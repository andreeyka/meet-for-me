//  MEE-290: управляющая поверхность `DomainTestKit.FakeAudioCapturePort`, названная
//  §«Фейк для тестов» C-004 дословно.
//
//  Граней пять: исход `start` — успех и ЛЮБАЯ `CaptureError`; любое событие в `events()`;
//  манифест `stop`; манифест `recover`, включая уже восстановленный; журнал вызовов С
//  АРГУМЕНТАМИ, отдаваемый тесту списком.
//
//  ШЕСТАЯ ГРАНЬ — ОТКАЗ `recover` — ПРОВЕРЯЕТСЯ ЗДЕСЬ И НАЗВАНА СВЕРХ ТЕКСТА КОНТРАКТА:
//  §«Фейк для тестов» C-004 даёт `recover` только манифест, а К77 плана MEE-288 требует ветви
//  «бросил `recoveryFailed`». Находка названа в отчёте MEE-290; текст C-004 не правится (§2
//  постановки).
//
//  ГРАНИЦА НАЗВАНА: ни одно утверждение этого файла не говорит о поведении ПОРТА. Манифесты
//  берутся у `RecordingManifestFixtures` — заводить свои контракт запрещает прямо.

import XCTest
import DomainCore
import DomainTestKit

final class FakeAudioCapturePortTests: XCTestCase {

    // MARK: - (а) исход `start`: успех и любая ошибка

    func test_mee290_fakeAudioCapture_startReturnsGivenValue() async throws {
        let port = FakeAudioCapturePort()
        let started = makeStarted()
        port.setStartResult(started)

        let answer = try await port.start(makeRequest())
        XCTAssertEqual(answer, started, "ответ — заданное значение, не приведённое ни к чему")
        XCTAssertEqual(port.recordedCalls.count, 1, "вектор непустоты: вызов записан")
    }

    func test_mee290_fakeAudioCapture_startThrowsAnyGivenError() async {
        let errors: [CaptureError] = [
            .systemAudioDenied,
            .systemAudioPromptTimedOut(waitedSeconds: 45),
            .microphoneDenied,
            .microphonePromptTimedOut(waitedSeconds: 45),
            .nothingToCapture
        ]
        for expected in errors {
            let port = FakeAudioCapturePort()
            port.failStart(with: expected)
            do {
                _ = try await port.start(makeRequest())
                XCTFail("ожидался отказ \(expected)")
            } catch let error as CaptureError {
                XCTAssertEqual(error, expected, "ошибка та, что задали")
            } catch {
                XCTFail("ожидалась CaptureError, получено \(error)")
            }
        }
        XCTAssertEqual(errors.count, 5, "вектор непустоты: перебор непуст, и цикл не проскочил")
    }

    /// Исход не задан вовсе — фейк отказывает громко, а не молча отдаёт выдуманное значение.
    func test_mee290_fakeAudioCapture_unsetStartOutcomeIsLoud() async {
        let port = FakeAudioCapturePort()
        do {
            _ = try await port.start(makeRequest())
            XCTFail("ожидался отказ: исход start не задан")
        } catch let error as CaptureError {
            guard case .systemUnavailable(let message) = error else {
                return XCTFail("ожидался systemUnavailable, получено \(error)")
            }
            XCTAssertTrue(message.contains("не задан"), "отказ называет причину: \(message)")
        } catch {
            XCTFail("ожидалась CaptureError, получено \(error)")
        }
    }

    // MARK: - (б) любое событие в поток

    func test_mee290_fakeAudioCapture_pushesAnyEventIntoStream() async {
        let port = FakeAudioCapturePort()
        let stream = port.events()          // поток берётся ДО толчка
        let pushed: [CaptureEvent] = [
            .started(makeStarted()),
            .systemSilent(sinceMs: 300_000),
            .promptPending(kind: .systemAudioRecording),
            .permissionObserved(kind: .systemAudioRecording, status: .denied),
            .levels(CaptureLevels(mic: nil, system: 0.5)),
            .paused(atMs: 1_000),
            .resumed(atMs: 2_000),
            .failed(.systemUnavailable(message: "Core Audio"))
        ]
        for event in pushed {
            port.emit(event)
        }
        port.finishEvents()

        var seen: [CaptureEvent] = []
        for await event in stream {
            seen.append(event)
        }
        XCTAssertEqual(seen.count, 8, "вектор непустоты: поток не пуст и не обрезан")
        XCTAssertEqual(seen, pushed, "значения доходят как есть и в порядке толчка")
    }

    // MARK: - (в) манифесты `stop` и `recover`

    func test_mee290_fakeAudioCapture_stopReturnsGivenManifest() async throws {
        let port = FakeAudioCapturePort()
        port.setStopManifest(RecordingManifestFixtures.hourlyTwoChannels)
        let manifest = try await port.stop()
        XCTAssertEqual(manifest, RecordingManifestFixtures.hourlyTwoChannels)
    }

    /// Уже восстановленный манифест — вход идемпотентности (инвариант 18 C-004). Фейк его
    /// отдаёт и ничего о самой идемпотентности не утверждает.
    func test_mee290_fakeAudioCapture_recoverReturnsGivenManifestTwice() async throws {
        let port = FakeAudioCapturePort()
        port.setRecoverManifest(RecordingManifestFixtures.truncatedRecovered)
        let directory = URL(fileURLWithPath: "/tmp/recordings/first")

        let first = try await port.recover(directory: directory)
        let second = try await port.recover(directory: directory)
        XCTAssertEqual(first, RecordingManifestFixtures.truncatedRecovered)
        XCTAssertEqual(second, first, "второй вызов отдаёт то же — это вход, а не проверка инварианта 18")
        XCTAssertEqual(port.callCount { $0 == .recover(directory: directory) }, 2, "оба вызова записаны")
    }

    func test_mee290_fakeAudioCapture_recoverThrowsRecoveryFailed() async {
        let port = FakeAudioCapturePort()
        let expected = CaptureError.recoveryFailed(directoryName: "first", message: "хвост потерян")
        port.failRecover(with: expected)
        do {
            _ = try await port.recover(directory: URL(fileURLWithPath: "/tmp/recordings/first"))
            XCTFail("ожидался отказ восстановления")
        } catch let error as CaptureError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("ожидалась CaptureError, получено \(error)")
        }
    }

    // MARK: - (г) журнал вызовов с аргументами

    func test_mee290_fakeAudioCapture_recordsEveryCallWithArguments() async throws {
        let log = PortCallLog()
        let port = FakeAudioCapturePort(log: log)
        port.setStartResult(makeStarted())
        port.setStopManifest(RecordingManifestFixtures.hourlyTwoChannels)
        XCTAssertTrue(port.recordedCalls.isEmpty, "вектор непустоты: до вызовов список пуст")

        let request = makeRequest()
        _ = try await port.start(request)
        try await port.pause()
        try await port.resume()
        try await port.setInput(.uid("BuiltInMicrophoneDevice"))
        _ = try await port.stop()

        XCTAssertEqual(
            port.recordedCalls,
            [.start(request), .pause, .resume, .setInput(.uid("BuiltInMicrophoneDevice")), .stop],
            "последовательность целиком, с аргументами"
        )
        XCTAssertEqual(
            log.signatures,
            [
                "AudioCapturePort.start(_:)",
                "AudioCapturePort.pause()",
                "AudioCapturePort.resume()",
                "AudioCapturePort.setInput(_:)",
                "AudioCapturePort.stop()"
            ],
            "тот же порядок в общем журнале — условие Н"
        )
    }

    /// Фейк не следит за порядком: `stop` до `start` проходит и отдаёт заданный манифест.
    /// Без этого ветку «потребитель пережил негодный порядок» не проверить ничем.
    func test_mee290_fakeAudioCapture_doesNotPoliceCallOrder() async throws {
        let port = FakeAudioCapturePort()
        port.setStopManifest(RecordingManifestFixtures.unfinished)
        let manifest = try await port.stop()
        XCTAssertEqual(manifest, RecordingManifestFixtures.unfinished)
        XCTAssertEqual(port.recordedCalls, [.stop], "вектор непустоты: вызов один и он записан")
    }

    // MARK: - Оснастка

    private func makeRequest() -> CaptureRequest {
        CaptureRequest(
            recordingId: RecordingManifestFixtures.hourlyTwoChannels.recordingId,
            meetingId: MeetingEventFixtures.oneOnOneZoom.id,
            directory: URL(fileURLWithPath: "/tmp/recordings/first"),
            group: ProcessGroup(appKey: "bundle:us.zoom.xos", pids: [4821], observedAt: Date(timeIntervalSince1970: 0)),
            input: .systemDefault,
            systemFormat: TrackFormat(sampleRate: 48_000, channelCount: 2),
            micFormat: TrackFormat(sampleRate: 48_000, channelCount: 1)
        )
    }

    private func makeStarted() -> CaptureStarted {
        CaptureStarted(
            recordingId: RecordingManifestFixtures.hourlyTwoChannels.recordingId,
            startedAt: Date(timeIntervalSince1970: 1_789_113_600),
            tracks: RecordingManifestFixtures.hourlyTwoChannels.tracks,
            captureGroupKey: "bundle:us.zoom.xos"
        )
    }
}
