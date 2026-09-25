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
    /// только то, что построчное чтение не режет и не повреждает кадр такого размера.
    func test_frameLargerThan8MiBRoundTripsIntact() async throws {
        try await withHangGuard {
            let transport = try ProcessRPCTransport(executablePath: "/usr/bin/env", arguments: ["cat"])
            let huge = String(repeating: "x", count: 9 * 1024 * 1024)
            try await transport.send(huge)
            let received = try await transport.receive()
            XCTAssertEqual(received.count, huge.count)
            XCTAssertEqual(received, huge)
            await transport.close()
        }
    }

    /// Процесс читает одну строку и выходит, не написав ничего в stdout — `receive()`
    /// обязан не зависнуть, а вернуть ошибку транспорта (детектируется и по EOF stdout,
    /// и по `terminationHandler`, какой из двух сработает первым).
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

    /// `close()` посылает SIGTERM и ждёт настоящего завершения процесса — по EOF `stdout`
    /// или по `terminationHandler`, какой сработает первым, плюс собственный 5с сторож
    /// внутри `ProcessRPCTransport.close()` (не сон по времени политики §5.2, а конечная
    /// подстраховка транспорта — МЕЕ-417: «не на стенных часах»), затем закрывает каналы —
    /// последующий `receive()` обязан отказать, не зависнуть.
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

/// Гонка с сигналом отмены, не с молчаливым системным киллом (МЕЕ-329 у самого `swift test`
/// уже проверяет собственный предел, но без единой строки о том, ГДЕ именно зависло —
/// возврат РП, приёмка PR #138, Linux). 10с — во много раз больше самого медленного
/// легитимного случая этого файла (9 МиБ через `Pipe`, ~1с даже с запасом), но много меньше
/// 300с общего предела `swift test`, так что провал одного теста здесь не съедает предел
/// остальных.
private struct ProcessRPCTransportTestHang: Error, CustomStringConvertible {
    var description: String { "зависание — не уложился в 10с (МЕЕ-417, диагностика Linux)" }
}

private func withHangGuard(
    seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line,
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
