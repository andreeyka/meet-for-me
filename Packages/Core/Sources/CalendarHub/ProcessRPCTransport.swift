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

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                onStderrLine(String(line))
            }
        }
        // `Task { [weak self] in … }` — капture-лист повторён НА САМОМ Task, не только на
        // объемлющем замыкании `readabilityHandler`: неявный захват уже-слабой локальной
        // `self` внешнего замыкания вложенным `Task { await self?...}` компилятор отвергает
        // («reference to captured var 'self' in concurrently-executing code» — внутренняя
        // ячейка слабой ссылки сама по себе мутабельна, и вложенное конкурентное замыкание
        // не вправе на неё молча полагаться). Свежий `[weak self]` на самом `Task` — тот же
        // приём, что и везде в этом файле, только явный дважды.
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { [weak self] in await self?.handleStdout(data) }
        }
        process.terminationHandler = { [weak self] proc in
            Task { [weak self] in await self?.handleTermination(status: proc.terminationStatus) }
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

    /// `withTaskCancellationHandler` — голый `withCheckedThrowingContinuation` не отвечает на
    /// отмену вызывающей задачи сам по себе (возврат РП, приёмка PR #138: тест-обвязка,
    /// гоняющая эту функцию наперегонки с тайм-аутом через `TaskGroup.cancelAll()`, иначе не
    /// смогла бы её реально прервать — отмена дошла бы до задачи, но не до уже висящего
    /// продолжения). `onCancel` не изолирован актором — хопает туда отдельным `Task`.
    public func receive() async throws -> String {
        if let line = try extractLine() { return line }
        if let terminated { throw terminated }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingReceive = continuation
            }
        } onCancel: {
            Task { await self.failPendingReceive(CancellationError()) }
        }
    }

    /// SIGTERM и закрытие каналов; возвращается, когда процесс вышел — по EOF `stdout`
    /// (`handleStdout`, тот же путь, что и обычная смерть процесса) или по
    /// `terminationHandler`, какой из двух сработает первым, плюс ограниченный сторож
    /// (`waitForExit`) на случай, если на конкретной платформе не сработает ни один
    /// (возврат РП: Linux, приёмка PR #138, — CI зависла именно здесь, `terminationHandler`
    /// swift-corelibs-foundation исторически ненадёжен; EOF `stdout` — ядерный, не
    /// Foundation-специфичный сигнал, сторож — конечная подстраховка, не политика тайм-аутов
    /// «Поведения» C-006 §5.2, которую и запрещает «не на стенных часах»).
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

    /// `String(bytes:encoding:)` — падающий инициализатор (SwiftLint
    /// `optional_data_string_conversion`), не `String(decoding:as:)`: тот молча заменяет
    /// невалидный UTF-8 символом-заменителем вместо отказа — «кадр не в UTF-8» стало бы
    /// неотличимо от кадра, которого никогда не присылали.
    private func extractLine() throws -> String? {
        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return nil }
        let lineBytes = buffer[..<newlineIndex]
        buffer.removeSubrange(buffer.startIndex...newlineIndex)
        guard let line = String(bytes: lineBytes, encoding: .utf8) else {
            throw ProcessRPCTransportError(description: "кадр не в UTF-8")
        }
        return line
    }

    private func handleStdout(_ data: Data) {
        guard !data.isEmpty else {
            markGone(ProcessRPCTransportError(description: "плагин закрыл stdout"))
            return
        }
        // `data.contains(0x0A)` — на самом ПРИШЕДШЕМ куске, до `append`, не на всём `buffer`
        // (замер CI, macOS: 69.7с на одном тесте К48-подобного размера, 9 МиБ через `Pipe` —
        // `FileHandle.readabilityHandler` там отдаёт кадр мелкими кусками по нескольку КиБ, и
        // `extractLine()`, зовись он на КАЖДЫЙ такой кусок, пересканировал бы уже проверенное
        // начало `buffer` заново — O(n·кусков), на практике квадратично от размера кадра.
        // Перевод строки — однобайтовый разделитель, не может «размазаться» по границе двух
        // кусков, поэтому его наличие в самом пришедшем куске — точный признак «искать в
        // buffer есть смысл», без ложных пропусков.
        let mayContainDelimiter = data.contains(0x0A)
        buffer.append(data)
        guard mayContainDelimiter else { return }
        do {
            guard let line = try extractLine(), let continuation = pendingReceive else { return }
            pendingReceive = nil
            continuation.resume(returning: line)
        } catch {
            failPendingReceive(error)
        }
    }

    private func handleTermination(status: Int32) {
        markGone(ProcessRPCTransportError(description: "процесс плагина завершился, код \(status)"))
    }

    /// Общая точка «процесса больше нет» для обоих независимых сигналов (EOF `stdout` в
    /// `handleStdout`, `terminationHandler` в `init`) — какой бы ни сработал первым, отказывает
    /// ожидающий `receive()` и снимает `waitForExit()` в `close()`. Идемпотентна: второй сигнал
    /// (обычно оба приходят почти одновременно) видит уже пустые `pendingExits`/`pendingReceive`.
    private func markGone(_ error: ProcessRPCTransportError) {
        if terminated == nil { terminated = error }
        failPendingReceive(error)
        for continuation in pendingExits { continuation.resume() }
        pendingExits.removeAll()
    }

    private func failPendingReceive(_ error: Error) {
        guard let continuation = pendingReceive else { return }
        pendingReceive = nil
        continuation.resume(throwing: error)
    }

    /// Сторож на 5 секунд — конечная подстраховка на случай, если ни EOF `stdout`, ни
    /// `terminationHandler` не сработают на конкретной платформе (не политика тайм-аутов
    /// «Поведения», см. докстринг `close()`): без него `close()` рисковал бы зависнуть
    /// навсегда, если оба сигнала почему-то молчат.
    private func waitForExit() async {
        if !process.isRunning { return }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.forceResolveExits()
        }
        await withCheckedContinuation { continuation in
            pendingExits.append(continuation)
        }
        watchdog.cancel()
    }

    private func forceResolveExits() {
        for continuation in pendingExits { continuation.resume() }
        pendingExits.removeAll()
    }
}
