//  ProcessRPCTransportTests — интеграционные тесты продового RPCTransport (МЕЕ-417).
//  Настоящий дочерний процесс, не `ScriptedRPCTransport`: `/usr/bin/env` + стандартные
//  утилиты POSIX (`cat`, `sh`), присутствующие и в контейнере `swift:5.10-jammy` (Core
//  (Linux)), и на раннере `macos-14` (Core + Mac) — не отдельный скрипт в ресурсах пакета,
//  чтобы не тащить исполнимый бит через копирование ресурсов SwiftPM между двумя
//  разными ОС в CI. Вне зоны перечня MEE-347 (§7 C-006: «реальный запуск процесса —
//  исключение»), поэтому без К-нумерации.
//
//  Покрытие по постановке МЕЕ-417: кадр туда-обратно, кадр больше 8 МиБ, смерть процесса,
//  shutdown (здесь — `close()`, см. ProcessRPCTransport.swift).
//
//  Возврат РП (приёмка PR #138, Linux): CI зависла на 300с без единой строки диагностики —
//  ProcessRPCTransportTests, реальный `Process`/`Pipe`, `terminationHandler`
//  swift-corelibs-foundation исторически ненадёжен. Каждый тест теперь обёрнут
//  `withHangGuard` — зависание (по любой причине, известной и ещё не известной) превращается
//  в чистый провал теста с диагностическим сообщением за 10с, не в слепой килл всей работы.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
@testable import CalendarHub

final class ProcessRPCTransportTests: XCTestCase {

    func test_roundTripFrameThroughRealEchoProcess() async throws {
        try await withHangGuard {
            let transport = try ProcessRPCTransport(executablePath: "/usr/bin/env", arguments: ["cat"])
            let frame = #"{"schemaVersion":1,"id":1,"result":{}}"#
            try await transport.send(frame)
            let received = try await transport.receive()
            XCTAssertEqual(received, frame)
            await transport.close()
        }
    }

    /// Кадр длиннее 8 МиБ туда-обратно, байт в байт — сам предел проверяет вызывающая
    /// сторона (`StdioCalendarConnector.awaitResponse`, §5.1), не транспорт; здесь важно
    /// только то, что построчное чтение не режет и не повреждает кадр такого размера, И что
    /// куски идут в правильном ПОРЯДКЕ.
    ///
    /// Содержимое — позиционно-зависимое (`makeNonRepeatingFrame`), не однородная строка из
    /// одних `x` (возврат РП, повторная приёмка PR #138, п. 1): перестановка местами двух
    /// кусков ОДИНАКОВОГО содержимого (все куски "x") дала бы БАЙТ-В-БАЙТ ТУ ЖЕ строку —
    /// `XCTAssertEqual` не поймал бы её вовсе, и заявление PR «порядок кусков гарантирован»
    /// оставалось неподтверждённым тестом.
    func test_frameLargerThan8MiBRoundTripsIntact() async throws {
        try await withHangGuard {
            let transport = try ProcessRPCTransport(executablePath: "/usr/bin/env", arguments: ["cat"])
            let huge = makeNonRepeatingFrame(totalBytes: 9 * 1024 * 1024)
            try await transport.send(huge)
            let received = try await transport.receive()
            XCTAssertEqual(received.count, huge.count)
            XCTAssertEqual(received, huge)
            await transport.close()
        }
    }

    /// Процесс читает одну строку и выходит, не написав ничего в stdout — `receive()`
    /// обязан не зависнуть, а вернуть ошибку транспорта. Детектируется по EOF `stdout`
    /// (`markGone`, `stdoutClosed`) — `terminationHandler` сам по себе `receive()` не отказывает
    /// (возврат РП, приёмка PR #138/MEE-424): здесь оба сигнала всё равно приходят практически
    /// одновременно (процесс не пишет ничего в stdout перед выходом), поэтому какой из двух
    /// первым долетит до актора — не важно для исхода этого теста.
    func test_processDeathSurfacesAsTransportErrorNotHang() async throws {
        try await withHangGuard {
            let transport = try ProcessRPCTransport(
                executablePath: "/usr/bin/env", arguments: ["sh", "-c", "read _line; exit 7"]
            )
            try await transport.send("первый кадр — план на прочтение и выход")

            do {
                _ = try await transport.receive()
                XCTFail("ожидалась транспортная ошибка после смерти процесса, не значение")
            } catch is ProcessRPCTransportError {
                // ожидаемо
            }
        }
    }

    /// Возврат РП (приёмка PR #138, MEE-424, п. 1-2): плагин отвечает и САМ выходит сразу после
    /// — `receive()` обязан вернуть настоящий ответ, даже если вызван уже ПОСЛЕ того, как
    /// `terminationHandler` отметил процесс мёртвым (реальный путь: `StdioCalendarConnector.
    /// awaitResponse` зовёт `receive()` не гонкой с самим `fetch`, а уже после того, как цикл
    /// синхронизации получил уведомление о завершении). `pollUntil` на `terminated != nil`, не
    /// сон по часам (возврат РП, приёмка PR #146, бэклог): гарантирует, что `terminationHandler`
    /// УЖЕ отработал ДО первого вызова `receive()` по факту события, не по угаданной задержке —
    /// `terminated`, а не `stdoutClosed`, потому что именно `terminationHandler` (не EOF) обычно
    /// успевает первым в этом сценарии (см. докстринг `recordTermination`), и это ровно тот
    /// сигнал, гонку с которым тест обязан гарантированно выиграть. До фикса (`if let terminated`
    /// в `receive()`) этот тест обязан был бы падать: `receive()` отказал бы транспортной
    /// ошибкой мимо уже записанного в `buffer`/на подходе в `AsyncStream` ответа.
    func test_receiveGetsResponseEvenAfterPluginAlreadyExited() async throws {
        try await withHangGuard {
            let transport = try ProcessRPCTransport(
                executablePath: "/usr/bin/env", arguments: ["sh", "-c", #"read l; echo "$l"; exit 0"#]
            )
            try await transport.send("привет-и-сразу-выхожу")
            await pollUntil { await transport.terminated != nil }

            let received = try await transport.receive()
            XCTAssertEqual(received, "привет-и-сразу-выхожу")

            do {
                _ = try await transport.receive()
                XCTFail("второй receive() после настоящего EOF stdout обязан отказать")
            } catch is ProcessRPCTransportError {
                // ожидаемо — на этот раз ответа больше нет, stdout действительно закрыт.
            }
        }
    }

    /// `close()` сначала закрывает `stdin` (EOF — штатный способ попросить `cat` выйти самому),
    /// затем, если процесс всё ещё жив, SIGTERM и SIGKILL — ждёт настоящего завершения по EOF
    /// `stdout`, плюс собственный сторож внутри `ProcessRPCTransport.close()` на каждом шаге (не
    /// сон по времени политики §5.2, а конечная подстраховка транспорта — МЕЕ-417: «не на
    /// стенных часах»), затем закрывает каналы — последующий `receive()` обязан отказать, не
    /// зависнуть.
    func test_closeTerminatesProcessThenReceiveFailsInsteadOfHanging() async throws {
        try await withHangGuard {
            let transport = try ProcessRPCTransport(executablePath: "/usr/bin/env", arguments: ["cat"])
            await transport.close()

            do {
                _ = try await transport.receive()
                XCTFail("после close() ожидалась ошибка, не значение")
            } catch {
                // ожидаемо — канал закрыт, процесс завершён.
            }
        }
    }

    /// Запуск несуществующего исполняемого файла — `Process.run()` бросает немедленно
    /// (`init` тоже `throws`), не оставляя частично сконструированный транспорт.
    func test_missingExecutableThrowsFromInitNotLater() {
        XCTAssertThrowsError(
            try ProcessRPCTransport(executablePath: "/no/such/executable-\(UUID().uuidString)")
        )
    }

    /// Возврат РП (приёмка PR #138, п. 3): запись в `stdin` уже умершего плагина (SIGPIPE) не
    /// убивает ХОСТ (этот тест-процесс) целиком — если бы `signal(SIGPIPE, SIG_IGN)` не
    /// сработал, весь `swift test` погиб бы молча, не показав ни `XCTFail`, ни зелёного
    /// прогона; сам факт завершения этого теста — часть доказательства.
    ///
    /// Возврат РП (повторная приёмка PR #138): версия с 50 попытками записи подряд без
    /// ожидания была гонкой с выходом процесса, а не детерминированной проверкой — на macOS
    /// все 50 писали успешно, ни разу не поймав ни EPIPE, ни собственный быстрый путь
    /// `send()` (`if let terminated`). Правильный порядок — дождаться, что `receive()` САМ
    /// обнаружил смерть процесса (через EOF/`terminationHandler`, что бы ни сработало первым),
    /// и только потом звать `send()`: тогда `terminated` уже точно выставлен, и `send()`
    /// обязан отказать немедленно быстрым путём, без гонки с самим фактом выхода процесса.
    func test_sendAfterProcessDeathThrowsTransportErrorNotCrashingHost() async throws {
        try await withHangGuard {
            let transport = try ProcessRPCTransport(executablePath: "/usr/bin/env", arguments: ["sh", "-c", "exit 0"])
            do {
                _ = try await transport.receive()
                XCTFail("процесс должен был выйти раньше, чем receive() успел бы получить значение")
            } catch {
                // ожидаемо — смерть процесса обнаружена (EOF stdout или terminationHandler).
            }
            do {
                try await transport.send("ping")
                XCTFail("ожидалась ошибка отправки в уже известный мёртвым процесс")
            } catch is ProcessRPCTransportError {
                // ожидаемо
            }
        }
    }

    /// Второй одновременный `receive()`, пока первый ещё не разрешился, — отказ, не
    /// молчаливая перезапись `pendingReceive` (возврат РП, бэклог): без защиты первый
    /// вызывающий терял бы своё продолжение навсегда, ничего не узнав об этом.
    func test_secondConcurrentReceiveIsRejectedNotSilentlyOverwritingFirst() async throws {
        try await withHangGuard {
            let transport = try ProcessRPCTransport(executablePath: "/usr/bin/env", arguments: ["cat"])
            async let first = transport.receive()
            // Даёт первому вызову время реально встать в `pendingReceive` до второго —
            // `cat` без входа ничего не пришлёт, первый вызов гарантированно подвиснет там.
            try await Task.sleep(for: .milliseconds(100))

            do {
                _ = try await transport.receive()
                XCTFail("второй одновременный receive() обязан отказать")
            } catch is ProcessRPCTransportError {
                // ожидаемо
            }

            try await transport.send("после-второго")
            let received = try await first
            XCTAssertEqual(received, "после-второго")
            await transport.close()
        }
    }

    /// `extractLine()` использует падающий `String(bytes:encoding:)`, не лениво-заменяющий
    /// `String(decoding:as:)` (возврат РП, SwiftLint `optional_data_string_conversion`) —
    /// невалидный UTF-8 обязан выйти ошибкой транспорта, не тихой заменой байт на U+FFFD.
    /// `python3 -c` вместо `sh -c "printf '\xff\xfe'"` — возврат РП (приёмка PR #138, Linux):
    /// `/bin/sh` в контейнере `swift:5.10-jammy` — `dash`, его `printf` не так надёжно
    /// поддерживает `\xHH`, как `bash` на macOS (тот же `sh`, но другой бинарник) — байты,
    /// скорее всего, доходили как ЛИТЕРАЛЬНЫЙ текст `\xff\xfe` (валидный UTF-8), не как байты
    /// 0xFF/0xFE, и тест падал не на транспорте, а на собственной непортируемой обвязке.
    /// Байтовый литерал Python — одинаков на обеих платформах CI (python3 гарантирован
    /// ci.yml).
    func test_invalidUTF8LineSurfacesAsTransportErrorNotSilentCorruption() async throws {
        try await withHangGuard {
            let transport = try ProcessRPCTransport(
                executablePath: "/usr/bin/env",
                arguments: ["python3", "-c", "import sys; sys.stdout.buffer.write(b'\\xff\\xfe\\n')"]
            )
            do {
                _ = try await transport.receive()
                XCTFail("ожидалась транспортная ошибка на не-UTF8 кадре, не тихая порча байт")
            } catch is ProcessRPCTransportError {
                // ожидаемо
            }
        }
    }

    /// МЕЕ-417: «запуск процесса плагина из манифеста» — `executable`/`args` манифеста, не
    /// голый путь напрямую, доходят до реального `Process`.
    func test_manifestBasedInitLaunchesExecutableAndArgsFromManifest() async throws {
        try await withHangGuard {
            let manifestJSON = Data(#"""
            {"schemaVersion":1,"id":"echo","name":"Echo","version":"1.0","protocolVersion":"1.0",
             "executable":"/usr/bin/env","args":["cat"],"networkHosts":[],"hostServices":[]}
            """#.utf8)
            let manifest = try PluginManifestLoader.parse(manifestJSON)
            let transport = try ProcessRPCTransport(manifest: manifest)
            try await transport.send("ping-по-манифесту")
            let received = try await transport.receive()
            XCTAssertEqual(received, "ping-по-манифесту")
            await transport.close()
        }
    }
}

/// Строка из блоков по 4 КиБ, каждый начинается со своего десятичного индекса — соседние
/// блоки заведомо различаются побайтово (возврат РП, повторная приёмка PR #138, п. 1), в
/// отличие от однородной `String(repeating: "x", …)`, перестановку двух кусков которой
/// байт-в-байт сравнение просто не может заметить. Без `\n` внутри (0x0A — разделитель
/// кадров самого транспорта) — только цифры и `x`-заполнитель.
private func makeNonRepeatingFrame(totalBytes: Int, blockSize: Int = 4096) -> String {
    var frame = ""
    frame.reserveCapacity(totalBytes)
    let blockCount = (totalBytes + blockSize - 1) / blockSize
    for blockIndex in 0..<blockCount {
        let marker = String(blockIndex)
        frame += marker + String(repeating: "x", count: blockSize - marker.count)
    }
    return frame
}

/// Гонка с сигналом отмены, не с молчаливым системным киллом (МЕЕ-329 у самого `swift test`
/// уже проверяет собственный предел, но без единой строки о том, ГДЕ именно зависло —
/// возврат РП, приёмка PR #138, Linux). 15с — с запасом больше самого медленного легитимного
/// случая этого файла: `close()` — сначала 1с грейс после EOF `stdin`, и, только если процесс
/// всё ещё жив, ДВА последовательных 5с сторожа `ProcessRPCTransport` (SIGTERM, затем SIGKILL,
/// см. докстринг `close()`) — то есть до ~11с само по себе в худшем случае, плюс кадр 9 МиБ —
/// 15с даёт запас, не впритык. На практике `stdin`-EOF решает почти все тестовые сценарии этого
/// файла ещё на грейс-периоде (миллисекунды), не доходя до сигналов вовсе. Много меньше 300с
/// общего предела `swift test`, так что провал одного теста здесь не съедает предел остальных.
private struct ProcessRPCTransportTestHang: Error, CustomStringConvertible {
    var description: String { "зависание — не уложился в 15с (МЕЕ-417, диагностика Linux)" }
}

private func withHangGuard(
    seconds: Double = 15, file: StaticString = #filePath, line: UInt = #line,
    _ operation: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ProcessRPCTransportTestHang()
        }
        do {
            try await group.next()
            group.cancelAll()
        } catch {
            group.cancelAll()
            if error is ProcessRPCTransportTestHang {
                XCTFail("\(error)", file: file, line: line)
            }
            throw error
        }
    }
}
