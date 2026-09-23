//  К27(б) — писатель, убитый SIGKILL, оставляет читаемый CAF и manifest.json, на котором
//  recover(directory:) работает без Core Audio и без TCC (способ Д, план MEE-315 §6).
//
//  Писатель — реальный процесс `CaptureManualHarness write` (тот же путь записи, что и у
//  реализации — package-видимые TrackFile/ManifestWriter, не собственный дубликат теста).

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class HarnessWriterKillTests: CaptureAsyncTestCase {

    /// URL собранного `CaptureManualHarness` — сосед `.xctest`-бандла этого теста в дереве сборки
    /// SwiftPM (`.build/<triple>/<config>/`), тот же приём, каким `swift test` уже собрал его вместе
    /// с этим таргетом (тот же пакет `Packages/Mac`, продукт строится заодно — план MEE-315 §6).
    private func harnessExecutableURL() throws -> URL {
        let buildDirectory = Bundle(for: HarnessWriterKillTests.self).bundleURL.deletingLastPathComponent()
        let url = buildDirectory.appendingPathComponent("CaptureManualHarness")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("CaptureManualHarness не найден рядом со сборкой теста: \(url.path)")
        }
        return url
    }

    func test_k27b_writerKilledBySigkillLeavesReadableTrackAndManifest() async throws {
        let harnessURL = try harnessExecutableURL()
        let directory = try Harness.makeDirectory()

        let process = Process()
        process.executableURL = harnessURL
        process.arguments = [
            "write", "--directory", directory.path, "--channel", "mic",
            "--sample-rate", "48000", "--channel-count", "1",
            "--chunk-frames", "480", "--chunk-interval-ms", "20"
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()

        // Ждём хотя бы несколько строк "wrote:" — писатель успел открыть трек, записать manifest.json
        // и дописать несколько порций — прежде чем убить его посреди работы, а не на старте.
        let handle = stdout.fileHandleForReading
        var buffered = Data()
        var wroteLines = 0
        let deadline = Date().addingTimeInterval(10)
        while wroteLines < 3, Date() < deadline {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { continue }
            buffered.append(chunk)
            wroteLines = (String(data: buffered, encoding: .utf8) ?? "")
                .components(separatedBy: "\n").filter { $0.hasPrefix("wrote:") }.count
        }
        XCTAssertGreaterThanOrEqual(wroteLines, 3, "писатель не успел записать ни одной порции за 10 с")

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)

        let files = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(files, ["audio-mic.caf", "manifest.json"], "ничего лишнего и ничего не потеряно")

        let frames = TrackFile.framesOnDisk(at: directory.appendingPathComponent("audio-mic.caf"), channelCount: 1)
        XCTAssertGreaterThan(frames, 0, "трек читается и после SIGKILL — заголовок CAF не повреждён")

        // recover(directory:) — способом порта, не руками: то же средство, каким домен
        // восстанавливает незавершённые записи после реального краха процесса.
        let recovered = try await Harness().port.recover(directory: directory)
        XCTAssertNotNil(recovered.endedAt)
        let discontinuity = try XCTUnwrap(recovered.discontinuities.first { $0.reason == .truncated })

        // Возврат MEE-317 (второй круг): `gapMs` здесь — заглушка-верхняя-граница, не измерение
        // (`СТРОКА` у `CaptureRecovery.recover` — по факту `write(2)` без пользовательской
        // буферизации, SIGKILL не теряет ничего, что уже дошло до `append`, и измерять
        // содержательно нечего). Эта проверка утверждает ровно то, что реализация делает сегодня —
        // gapMs равен бюджету сброса, — а не то, что список считает это правильным поведением;
        // сама трактовка списка («совпадает по порядку с интервалом сброса») открыта в отчёте.
        XCTAssertEqual(discontinuity.gapMs, AudioCaptureLimits.truncatedTailBudgetMs,
                       "текущий выбор реализации — заглушка равна бюджету сброса, см. СТРОКА в CaptureRecovery")
    }
}
