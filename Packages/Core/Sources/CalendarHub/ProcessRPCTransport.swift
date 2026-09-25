//  ProcessRPCTransport — продовый RPCTransport (C-006 §2, MEE-417/MEE-402 шаг 3) поверх
//  Process/Pipe/FileHandle: запуск процесса плагина, кадрирование stdio (одна строка JSON на
//  кадр через stdin/stdout), stderr — колбэком вызывающего в журнал, смерть процесса —
//  транспортная ошибка (`StdioCalendarConnector.awaitResponse`/`call` заворачивают любую
//  ошибку `receive()`/`send()` в `ConnectorError.upstreamUnavailable`, разбирать конкретный
//  тип им не нужно), shutdown — SIGTERM и закрытие каналов, не средствами RPCTransport
//  (протокол их не называет — см. Seams.swift), а отдельным методом `close()` этого типа.
//
//  Предел 8 МиБ на кадр здесь НЕ проверяется: `StdioCalendarConnector.awaitResponse` уже
//  делает это после `receive()` (§5.1). Здесь важно не повредить кадр большего размера при
//  чтении, не отклонить его заранее — реальный запуск процесса вне зоны перечня MEE-347
//  (§7: «реальное чтение файла/запуск процесса — исключение»), поэтому у этого файла
//  собственный интеграционный тест (MEE-417), не К-критерий.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation

/// Ошибка транспорта: смерть процесса плагина, закрытый канал. `StdioCalendarConnector` не
/// разбирает конкретный тип отдельно (см. заголовок файла) — текстового описания достаточно.
/// Без `CustomStringConvertible` (не входит в разрешённый список поверхности calendar-hub,
/// `.github/scripts/allowed-types/CalendarHub.json`, MEE-191): `"\(error)"` вызывающей
/// стороны получает используемый по умолчанию дамп структуры — читаемость ниже, но текст
/// `description` внутри всё равно виден, а расширение чужого списка не по контракту этой
/// задачи не решается.
public struct ProcessRPCTransportError: Error, Sendable {
    public let description: String
}

/// Продовый `RPCTransport` — запускает плагин `Process`ом, кадрирует stdio по одной строке
/// JSON на кадр. Чтение `stdout`/`stderr` — через `FileHandle.readabilityHandler`
/// (диспетчер GCD, вне кооперативного пула Swift concurrency): запись большого кадра в
/// `stdin` поэтому не может столкнуться в клинче с чтением того же кадра обратно у процесса,
/// который его немедленно эхо-заворачивает (тестовый случай "кадр больше 8 МиБ") — ядро
/// дренирует канал GCD-обработчиком независимо от того, когда актор обработает уже
/// прочитанные байты.
public actor ProcessRPCTransport: RPCTransport {

    private let process = Process()
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private var buffer = Data()
    private var pendingReceive: CheckedContinuation<String, Error>?
    private var pendingExits: [CheckedContinuation<Void, Never>] = []
    private var terminated: ProcessRPCTransportError?

    public init(
        executablePath: String,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        onStderrLine: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let currentDirectoryURL { process.currentDirectoryURL = currentDirectoryURL }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        try process.run()

        // Свободные функции/замыкания ниже не изолированы актором — только после этой
        // точки `self` полностью инициализирован, и `[weak self]` в них законен.
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                onStderrLine(String(line))
            }
        }
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.handleStdout(data) }
        }
        process.terminationHandler = { [weak self] proc in
            Task { await self?.handleTermination(status: proc.terminationStatus) }
        }
    }

    /// Запуск из манифеста плагина (МЕЕ-417: «запуск процесса плагина из манифеста»).
    /// `internal`, не `public` — `PluginManifest` сам internal (C-006 §7), и публичный
    /// инициализатор не вправе называть его в подписи; композиция вызывает этот же файл
    /// изнутри модуля calendar-hub (архитектор, записка MEE-402 шаг 1: «всё — Core»).
    init(
        manifest: PluginManifest,
        currentDirectoryURL: URL? = nil,
        onStderrLine: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        try self.init(
            executablePath: manifest.executable, arguments: manifest.args,
            currentDirectoryURL: currentDirectoryURL, onStderrLine: onStderrLine
        )
    }

    public func send(_ frame: String) async throws {
        if let terminated { throw terminated }
        var data = Data(frame.utf8)
        data.append(0x0A)
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            throw ProcessRPCTransportError(description: "запись в stdin плагина не удалась: \(error)")
        }
    }

    public func receive() async throws -> String {
        if let line = extractLine() { return line }
        if let terminated { throw terminated }
        return try await withCheckedThrowingContinuation { continuation in
            pendingReceive = continuation
        }
    }

    /// SIGTERM и закрытие каналов; возвращается, только когда процесс действительно вышел —
    /// через `terminationHandler` (МЕЕ-417: «не на стенных часах»), не через сон по времени.
    /// Не часть `RPCTransport` (протокол не называет остановку процесса — Seams.swift, «форма
    /// — решение этой задачи»): вызывающая сторона зовёт его отдельно от
    /// `CalendarConnector.shutdown()` (тот шлёт JSON-RPC уведомление тем же транспортом,
    /// этот метод сам процесс не трогает).
    public func close() async {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            await waitForExit()
        }
        try? stdinHandle.close()
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    // MARK: - Внутреннее

    private func extractLine() -> String? {
        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = String(decoding: buffer[..<newlineIndex], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...newlineIndex)
        return line
    }

    private func handleStdout(_ data: Data) {
        guard !data.isEmpty else {
            failPendingReceive(ProcessRPCTransportError(description: "плагин закрыл stdout"))
            return
        }
        buffer.append(data)
        guard let line = extractLine(), let continuation = pendingReceive else { return }
        pendingReceive = nil
        continuation.resume(returning: line)
    }

    private func handleTermination(status: Int32) {
        let error = ProcessRPCTransportError(description: "процесс плагина завершился, код \(status)")
        terminated = error
        failPendingReceive(error)
        for continuation in pendingExits { continuation.resume() }
        pendingExits.removeAll()
    }

    private func failPendingReceive(_ error: Error) {
        guard let continuation = pendingReceive else { return }
        pendingReceive = nil
        continuation.resume(throwing: error)
    }

    private func waitForExit() async {
        if !process.isRunning { return }
        await withCheckedContinuation { continuation in
            pendingExits.append(continuation)
        }
    }
}
