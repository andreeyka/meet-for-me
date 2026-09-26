//  ProcessRPCTransport — продовый RPCTransport (C-006 §2, MEE-417/MEE-402 шаг 3) поверх
//  Process/Pipe/FileHandle: запуск процесса плагина, кадрирование stdio (одна строка JSON на
//  кадр через stdin/stdout), stderr — колбэком вызывающего в журнал, смерть процесса —
//  транспортная ошибка (`StdioCalendarConnector.awaitResponse`/`call` заворачивают любую
//  ошибку `receive()`/`send()` в `ConnectorError.upstreamUnavailable`, разбирать конкретный
//  тип им не нужно), shutdown — SIGTERM/SIGKILL и закрытие каналов, не средствами
//  RPCTransport (протокол их не называет — см. Seams.swift), а отдельным методом `close()`.
//
//  Этот файл — публичная поверхность и жизненный цикл (`init`/`send`/`receive`/`close`/
//  `deinit`); внутренние обработчики (`extractLine`, `handleStdout`/`handleStderr`,
//  `markGone`, `waitForExit`) — `ProcessRPCTransport+Internals.swift`, тот же приём
//  file_length/type_body_length, что у соседних составных типов модуля
//  (`InMemoryMeetingRepository+Absorbing.swift` и т.п.): SwiftLint считает каждый файл
//  отдельно, не суммой по типу. Члены, которым нужен доступ из обоих файлов, — internal
//  (`private` в Swift ограничен ОДНИМ файлом, включая расширения того же типа в других
//  файлах), не публичная поверхность модуля наружу — извне видны только `send`/`receive`/
//  `close`/оба `init`, как и раньше.
//
//  Предел 8 МиБ на кадр здесь НЕ проверяется: `StdioCalendarConnector.awaitResponse` уже
//  делает это после `receive()` (§5.1). Здесь важно не повредить кадр большего размера при
//  чтении, не отклонить его заранее — реальный запуск процесса вне зоны перечня MEE-347
//  (§7: «реальное чтение файла/запуск процесса — исключение»), поэтому у этого файла
//  собственный интеграционный тест (MEE-417), не К-критерий.
//
//  `signal`/`kill`/`SIGPIPE`/`SIGKILL` ниже — без явного `import Darwin`/`import Glibc`
//  (К58, `.github/scripts/calendar-hub-surface.py`, `ALLOWED_IMPORTS = {Foundation,
//  DomainCore}`, запрещает оба явно) — рассчёт на то, что `Foundation` транзитивно делает
//  эти POSIX-символы видимыми на обеих платформах (так исторически было и остаётся почти
//  везде, где `Foundation`/`swift-corelibs-foundation` сама не помечает свой внутренний
//  `import Darwin`/`import Glibc` как `@_implementationOnly`). Подтверждено прогоном CI
//  (единственный доступный способ проверки без локального тулчейна) — не гипотеза,
//  оставленная непроверенной.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation

/// Ошибка транспорта: смерть процесса плагина, закрытый канал, отказ записи в stdin.
/// `StdioCalendarConnector` не разбирает конкретный тип отдельно (см. заголовок файла) —
/// текстового описания достаточно. Без `CustomStringConvertible` (не входит в разрешённый
/// список поверхности calendar-hub, `.github/scripts/allowed-types/CalendarHub.json`,
/// MEE-191): `"\(error)"` вызывающей стороны получает используемый по умолчанию дамп
/// структуры — читаемость ниже, но текст `description` внутри всё равно виден, а расширение
/// чужого списка не по контракту этой задачи не решается.
public struct ProcessRPCTransportError: Error, Sendable {
    public let description: String
}

/// Продовый `RPCTransport` — запускает плагин `Process`ом, кадрирует stdio по одной строке
/// JSON на кадр. Чтение `stdout`/`stderr` — через `FileHandle.readabilityHandler` (диспетчер
/// GCD, вне кооперативного пула Swift concurrency), каждый обработчик СИНХРОННО отдаёт кусок
/// в свой `AsyncStream`, и уже единственный потребитель каждого потока разбирает куски по
/// порядку прихода (возврат РП, приёмка PR #138: `Task` на каждый кусок из обработчика не
/// гарантирует порядок входа в актор — независимые задачи Swift планирует не обязательно в
/// порядке создания, и куски кадра ≥1 МиБ через несколько вызовов `readabilityHandler` могли
/// переставиться местами).
public actor ProcessRPCTransport: RPCTransport {

    let process = Process()
    let stdinHandle: FileHandle
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle
    var buffer = Data()
    var stderrBuffer = Data()
    var pendingReceive: CheckedContinuation<String, Error>?
    var pendingExits: [CheckedContinuation<Void, Never>] = []
    var terminated: ProcessRPCTransportError?
    var stdoutClosed: ProcessRPCTransportError?
    let stdoutContinuation: AsyncStream<Data>.Continuation
    /// Аналог `stdoutClosed` для `stderr` (МЕЕ-444) — булев, не `ProcessRPCTransportError?`:
    /// `stderr` не несёт транспортной ошибки наружу (`StdioCalendarConnector` его не читает,
    /// только журналирует построчно через `onStderrLine`), здесь важен только сам факт «дошёл
    /// до настоящего EOF», см. `waitForStdioEOF`.
    var stderrEOFObserved = false
    var pendingStdioEOF: [CheckedContinuation<Void, Never>] = []

    /// Один раз на процесс хоста, а не на транспорт: `signal()` — глобальная настройка, не
    /// свойство одного дескриптора (переносимого `F_SETNOSIGPIPE`, доступного только на
    /// Darwin, здесь нет — портируемо только так). Без этого запись в `stdin` уже умершего
    /// плагина (SIGPIPE, обработчик по умолчанию — завершение ВСЕГО процесса хоста, не только
    /// этого actor'а) убила бы CI/приложение целиком (возврат РП, приёмка PR #138, п. 3).
    private static let sigpipeIgnored: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    public init(
        executablePath: String,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        onStderrLine: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        _ = Self.sigpipeIgnored
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

        let (stdoutStream, stdoutContinuationForHandler) = Self.makeByteStream()
        stdoutContinuation = stdoutContinuationForHandler
        let (stderrStream, stderrContinuationForHandler) = Self.makeByteStream()

        try process.run()
        // Возврат РП (приёмка PR #138): родитель обязан закрыть СВОИ копии концов каждого
        // канала, которыми пользуется только ребёнок — см. докстринг `closeParentSideOfPipes`.
        Self.closeParentSideOfPipes(stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
        Self.installReadabilityHandler(on: stdoutHandle, continuation: stdoutContinuationForHandler)
        Self.installReadabilityHandler(on: stderrHandle, continuation: stderrContinuationForHandler)

        process.terminationHandler = { [weak self] proc in
            Task { [weak self] in await self?.handleTermination(status: proc.terminationStatus) }
        }
        Task { [weak self] in
            for await data in stdoutStream {
                guard let self else { return }
                await self.handleStdout(data)
            }
        }
        Task { [weak self] in
            for await data in stderrStream {
                guard let self else { return }
                // Пустой кусок — настоящий EOF `stderr` (тот же признак, что `handleStdout`
                // использует для `markGone`), не просто «нечего разбирать построчно» — МЕЕ-444:
                // `close()` обязан дождаться этого сигнала, не только смерти самого процесса,
                // прежде чем трогать дескриптор, см. `waitForStdioEOF`.
                guard !data.isEmpty else {
                    await self.markStderrEOFObserved()
                    return
                }
                await self.handleStderr(data, onLine: onStderrLine)
            }
        }
    }

    /// `let`, не `var` — «reference to captured var в конкурентно исполняющемся коде»: `var`
    /// внутри нужен только чтобы выбраться из замыкания `AsyncStream.init`, наружу отдаётся
    /// уже неизменяемое значение — единственное, что вправе захватывать
    /// `installReadabilityHandler` ниже. `static`, не изолирован актором — вызывается из
    /// `init`, где `await` невозможен вообще.
    private static func makeByteStream() -> (AsyncStream<Data>, AsyncStream<Data>.Continuation) {
        var captured: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation in captured = continuation }
        return (stream, captured)
    }

    /// Обработчик не захватывает `self` вовсе (ни прямо, ни через `[weak self]`) — снимает
    /// сам себя на EOF (возврат РП, п. 2: раньше это делал только `close()`, и после EOF
    /// обработчик продолжал вызываться вхолостую) и синхронно передаёт кусок дальше через
    /// continuation своего потока; порядок и разбор — забота потребителя (`init`, единственный).
    private static func installReadabilityHandler(on handle: FileHandle, continuation: AsyncStream<Data>.Continuation) {
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil }
            continuation.yield(data)
        }
    }

    /// Родительская, никем не читаемая/не записываемая копия конца канала держит его
    /// «открытым» с точки зрения ядра ПОСЛЕ смерти ребёнка, даже когда ребёнок закрыл свою
    /// — иначе ни `write()` в `stdin` никогда не даёт EPIPE (`test_sendAfterProcessDeath...`,
    /// приёмка PR #138), ни EOF `stdout`/`stderr` никогда не наступает по-настоящему
    /// (правдоподобное объяснение и того самого 5с сторожа на Linux — «настоящего сигнала»
    /// не было в принципе, не только «сработал не вовремя»).
    private static func closeParentSideOfPipes(stdin: Pipe, stdout: Pipe, stderr: Pipe) {
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
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

    /// Запись — вне актора (`Task.detached`): плагин, который не читает свой `stdin`,
    /// блокировал бы блокирующий `write()` НАВСЕГДА, а вместе с ним — весь актор, включая
    /// `close()` (возврат РП, приёмка PR #138, п. 3, вторая половина). SIGPIPE на запись в
    /// уже закрытый канал теперь не убивает хост (`sigpipeIgnored` выше) — `write(contentsOf:)`
    /// вместо этого бросает обычной ошибкой (`EPIPE`), заворачиваемой ниже как обычно.
    public func send(_ frame: String) async throws {
        if let terminated { throw terminated }
        // `let`, не `var` + `.append` — тот же класс ошибки, что и захват `self` в `init`
        // («reference to captured var в конкурентно исполняющемся коде»): `Task.detached`
        // ниже требует неизменяемого захваченного значения, не мутируемой локальной переменной.
        let data = Data(frame.utf8) + [0x0A]
        let handle = stdinHandle
        do {
            try await Task.detached(priority: .utility) {
                try handle.write(contentsOf: data)
            }.value
        } catch {
            throw ProcessRPCTransportError(description: "запись в stdin плагина не удалась: \(error)")
        }
    }

    /// `withTaskCancellationHandler` — голый `withCheckedThrowingContinuation` не отвечает на
    /// отмену вызывающей задачи сам по себе (возврат РП, приёмка PR #138: тест-обвязка,
    /// гоняющая эту функцию наперегонки с тайм-аутом через `TaskGroup.cancelAll()`, иначе не
    /// смогла бы её реально прервать — отмена дошла бы до задачи, но не до уже висящего
    /// продолжения). `onCancel` не изолирован актором — хопает туда отдельным `Task`.
    /// Второй одновременный вызов, пока первый ещё не разрешился, — отказ, а не молчаливая
    /// перезапись `pendingReceive` (возврат РП, бэклог): без проверки первый вызывающий терял
    /// бы своё продолжение навсегда, ничего не узнав об этом.
    ///
    /// `stdoutClosed`, не `terminated` (возврат РП, приёмка PR #138, MEE-424, п. 1): `terminated`
    /// ставит и `terminationHandler` (`recordTermination`) — ядерный сигнал о выходе процесса,
    /// который может дойти до актора РАНЬШЕ, чем потребитель `AsyncStream` разберёт ещё не
    /// прочитанный последний кусок `stdout` с фактическим ответом плагина (тот же класс гонки,
    /// что markGone/recordTermination уже решают для УЖЕ висящего `pendingReceive` — здесь тот же
    /// вопрос для ЕЩЁ НЕ начатого вызова: `StdioCalendarConnector.awaitResponse` реально зовёт
    /// `receive()` уже ПОСЛЕ уведомления о том, что плагин завершился). Проверять здесь `terminated`
    /// значило бы отказывать немедленно, даже когда ответ уже записан и вот-вот дойдёт до `buffer`
    /// — `stdoutClosed` ставит только `markGone`, только на настоящем EOF `stdout`, когда буфер
    /// уже гарантированно вычитан весь и никакого ответа потерять невозможно.
    public func receive() async throws -> String {
        if let line = try extractLine() { return line }
        if let stdoutClosed { throw stdoutClosed }
        guard pendingReceive == nil else {
            throw ProcessRPCTransportError(description: "receive() уже вызван — второй одновременный вызов запрещён")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingReceive = continuation
            }
        } onCancel: {
            Task { await self.failPendingReceive(CancellationError()) }
        }
    }

    /// Сначала EOF на `stdin` (штатный способ попросить stdio-плагин завершиться самому —
    /// многие процессы, включая интеграционные тесты этого файла, читают до EOF и выходят
    /// добровольно, без единого сигнала), короткий грейс (1с), и только потом — SIGTERM, затем
    /// SIGKILL, если процесс его проигнорировал (возврат РП, приёмка PR #138, п. 4) —
    /// `Process` не даёт выбрать сигнал напрямую (`terminate()` — всегда SIGTERM), поэтому
    /// эскалация — сырой `kill(pid, SIGKILL)`. Возвращается, когда процесс вышел — по EOF
    /// `stdout`/`stderr` (`pendingExits` резолвится и оттуда, и из `terminationHandler`, какой
    /// сработает первым, см. `recordTermination`), плюс ограниченный сторож (`waitForExit`) на
    /// случай, если на конкретной платформе не сработает ни один.
    ///
    /// EOF на `stdin` — не только более корректный порядок для прода (вызывающая сторона уже
    /// отправила JSON-RPC shutdown-уведомление через `send()` до `close()`, EOF — естественное
    /// продолжение той же идеи «больше кадров не будет»), но и то, что устранило известную
    /// задержку ~5с на Linux CI (`swift:5.10-jammy`). Причина найдена и подтверждена (не
    /// гипотеза): ребёнок наследует через `exec` маску БЛОКИРОВАННЫХ сигналов ПОТОКА, из
    /// которого запущен `process.run()` (POSIX сохраняет маску блокировки через `exec`, в
    /// отличие от диспозиции обработчиков) — на потоках кооперативного пула Swift concurrency
    /// на Linux `SIGTERM` заблокирован, и живой ребёнок его просто никогда не получает; `SIGKILL`
    /// блокировке не подчиняется, поэтому убивает мгновенно. Подтверждено печатью
    /// `/proc/<pid>/status` САМОГО ребёнка застрявшего теста (`SigBlk` содержал бит SIGTERM) —
    /// первая попытка проверить эту же гипотезу отдельным диагностическим тестом ошибочно её не
    /// подтвердила, потому что тот тест сам оказался запущен с другого потока с чистой маской.
    /// Обход, не устранение причины (сброс маски дочернего процесса потребовал бы
    /// `posix_spawnattr_setsigmask`/`SETSIGDEF`, которых `Process` не даёт, а прямой
    /// `posix_spawn` — `import Darwin`/`import Glibc`, запрещённых К58 для calendar-hub, см.
    /// бэклог): раз процесс, читающий до EOF, всё равно выходит сам (естественный `exit()`, без
    /// единого сигнала), `close()` даёт ему этот шанс ДО того, как вообще понадобится `SIGTERM`.
    /// Сторож остаётся конечной подстраховкой — не политика тайм-аутов «Поведения» C-006 §5.2,
    /// которую и запрещает «не на стенных часах» — на случай плагина, что сам не выходит по EOF
    /// `stdin`; в проде (только macOS, C-006 §7) `SIGTERM` работает штатно независимо от этого.
    /// Не часть `RPCTransport` (протокол не называет остановку процесса — Seams.swift, «форма
    /// — решение этой задачи»): вызывающая сторона зовёт его отдельно от
    /// `CalendarConnector.shutdown()` (тот шлёт JSON-RPC уведомление тем же транспортом,
    /// этот метод сам процесс не трогает).
    public func close() async {
        try? stdinHandle.close()
        if process.isRunning {
            await waitForExit(timeoutSeconds: 1)
        }
        if process.isRunning {
            process.terminate()
            await waitForExit()
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                await waitForExit()
            }
        }
        // МЕЕ-444 (диагностика SIGSEGV на Linux, «bad pointer dereference», CI run
        // 108070063812): смерть процесса (`waitForExit` выше) и настоящий EOF `stdout`/`stderr`
        // — НЕЗАВИСИМЫЕ сигналы (тот же класс гонки, что `recordTermination`/`markGone` уже
        // решают для `pendingReceive`, см. их докстринги) — `terminationHandler` мог долететь
        // РАНЬШЕ, чем диспетчерский источник чтения `stdout`/`stderr` вообще успел сработать
        // хоть раз. Полный довод и причина падения — докстринг `waitForStdioEOF`
        // (ProcessRPCTransport+Internals.swift).
        await waitForStdioEOF()
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    /// Лучшее усилие на уничтожении: `close()` не вызван — `deinit` актора выполняется вне
    /// изоляции (никакого `await` здесь быть не может), поэтому сигнал только посылается, не
    /// дожидается выхода (возврат РП, приёмка PR #138, п. 4 — раньше не забытый процесс плагина
    /// без явного `close()` не завершался вовсе).
    deinit {
        if process.isRunning {
            process.terminate()
        }
    }
}
