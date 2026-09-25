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
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
@testable import CalendarHub

final class ProcessRPCTransportTests: XCTestCase {

    func test_roundTripFrameThroughRealEchoProcess() async throws {
        let transport = try ProcessRPCTransport(executablePath: "/usr/bin/env", arguments: ["cat"])
        let frame = #"{"schemaVersion":1,"id":1,"result":{}}"#
        try await transport.send(frame)
        let received = try await transport.receive()
        XCTAssertEqual(received, frame)
        await transport.close()
    }

    /// Кадр длиннее 8 МиБ туда-обратно, байт в байт — сам предел проверяет вызывающая
    /// сторона (`StdioCalendarConnector.awaitResponse`, §5.1), не транспорт; здесь важно
    /// только то, что построчное чтение не режет и не повреждает кадр такого размера.
    func test_frameLargerThan8MiBRoundTripsIntact() async throws {
        let transport = try ProcessRPCTransport(executablePath: "/usr/bin/env", arguments: ["cat"])
        let huge = String(repeating: "x", count: 9 * 1024 * 1024)
        try await transport.send(huge)
        let received = try await transport.receive()
        XCTAssertEqual(received.count, huge.count)
        XCTAssertEqual(received, huge)
        await transport.close()
    }

    /// Процесс читает одну строку и выходит, не написав ничего в stdout — `receive()`
    /// обязан не зависнуть, а вернуть ошибку транспорта (детектируется и по EOF stdout,
    /// и по `terminationHandler`, какой из двух сработает первым).
    func test_processDeathSurfacesAsTransportErrorNotHang() async throws {
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

    /// `close()` посылает SIGTERM и ждёт настоящего завершения процесса через
    /// `terminationHandler` (не сон по времени, МЕЕ-417: «не на стенных часах»), затем
    /// закрывает каналы — последующий `receive()` обязан отказать, не зависнуть.
    func test_closeTerminatesProcessThenReceiveFailsInsteadOfHanging() async throws {
        let transport = try ProcessRPCTransport(executablePath: "/usr/bin/env", arguments: ["cat"])
        await transport.close()

        do {
            _ = try await transport.receive()
            XCTFail("после close() ожидалась ошибка, не значение")
        } catch {
            // ожидаемо — канал закрыт, процесс завершён.
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
    func test_invalidUTF8LineSurfacesAsTransportErrorNotSilentCorruption() async throws {
        let transport = try ProcessRPCTransport(
            executablePath: "/usr/bin/env", arguments: ["sh", "-c", "printf '\\xff\\xfe\\n'"]
        )
        do {
            _ = try await transport.receive()
            XCTFail("ожидалась транспортная ошибка на не-UTF8 кадре, не тихая порча байт")
        } catch is ProcessRPCTransportError {
            // ожидаемо
        }
    }

    /// МЕЕ-417: «запуск процесса плагина из манифеста» — `executable`/`args` манифеста, не
    /// голый путь напрямую, доходят до реального `Process`.
    func test_manifestBasedInitLaunchesExecutableAndArgsFromManifest() async throws {
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
