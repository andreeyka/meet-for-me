//  ProcessRPCTransport+Internals — обработчики кадрирования stdout/stderr, детектирование
//  смерти процесса, сторож `close()`. Деление по объёму, не по смыслу — тот же приём, что
//  `ProcessRPCTransport.swift` уже объясняет в своей шапке (SwiftLint file_length/
//  type_body_length считают каждый файл отдельно). Члены здесь читают/пишут хранимые
//  свойства актора, объявленные `ProcessRPCTransport.swift` — намеренно `internal`, не
//  `private` (та ограничена одним файлом), но за пределы модуля calendar-hub не выходят:
//  публичная поверхность типа снаружи не меняется ни на строку.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation

extension ProcessRPCTransport {

    /// `String(bytes:encoding:)` — падающий инициализатор (SwiftLint
    /// `optional_data_string_conversion`), не `String(decoding:as:)`: тот молча заменяет
    /// невалидный UTF-8 символом-заменителем вместо отказа — «кадр не в UTF-8» стало бы
    /// неотличимо от кадра, которого никогда не присылали.
    func extractLine() throws -> String? {
        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return nil }
        let lineBytes = buffer[..<newlineIndex]
        buffer.removeSubrange(buffer.startIndex...newlineIndex)
        guard let line = String(bytes: lineBytes, encoding: .utf8) else {
            throw ProcessRPCTransportError(description: "кадр не в UTF-8")
        }
        return line
    }

    func handleStdout(_ data: Data) {
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
        // `pendingReceive == nil` — не трогать `buffer` через `extractLine()` вовсе (возврат РП,
        // приёмка PR #138, MEE-424, п. 1/2): та не только читает, но и УДАЛЯЕТ строку из
        // `buffer` безусловно. Если бы вызвать её здесь, пока `receive()` ещё не позвали
        // (плагин ответил и сразу вышел ДО того, как вызывающая сторона обратилась за ответом —
        // реальный путь `StdioCalendarConnector.awaitResponse`), извлечённая строка была бы
        // просто отброшена (отдать её некому) и потеряна НАВСЕГДА — не осталась бы в `buffer`
        // для следующего вызова `receive()`, у которого есть свой собственный `extractLine()` в
        // самом начале, как раз на этот случай.
        guard mayContainDelimiter, let continuation = pendingReceive else { return }
        do {
            guard let line = try extractLine() else { return }
            pendingReceive = nil
            continuation.resume(returning: line)
        } catch {
            failPendingReceive(error)
        }
    }

    /// Буферизация строк `stderr` тем же приёмом, что `stdout` (возврат РП, бэклог: наивный
    /// `text.split(separator: "\n")` на КАЖДОМ куске рвал сообщение на границе куска, если оно
    /// не помещалось в один кусок целиком). Невалидный UTF-8 внутри одной строки отбрасывает
    /// только её — не бросает и не останавливает разбор дальнейших строк: `stderr` плагина —
    /// диагностика, не протокол, и не обязана валить транспорт из-за мусора в логе.
    func handleStderr(_ data: Data, onLine: (String) -> Void) {
        stderrBuffer.append(data)
        while let newlineIndex = stderrBuffer.firstIndex(of: 0x0A) {
            let lineBytes = stderrBuffer[..<newlineIndex]
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...newlineIndex)
            if let line = String(bytes: lineBytes, encoding: .utf8) {
                onLine(line)
            }
        }
    }

    /// `terminationHandler` (ядерный сигнал о выходе процесса) сам по себе НЕ отказывает
    /// `receive()` — только `recordTermination` (возврат РП, повторная приёмка PR #138, п. 3):
    /// сигнал о смерти процесса и сигнал «весь stdout вычитан» независимы и могут прийти в
    /// любом порядке. Если плагин успел записать ответ и выйти, а `terminationHandler` (на
    /// Linux ненадёжный по ВРЕМЕНИ, не только по факту) обогнал ещё не разобранный
    /// потребителем `AsyncStream` последний кусок stdout — при старом поведении (`markGone`
    /// отсюда) `pendingReceive` был бы отказан ДО того, как этот кусок дойдёт до
    /// `handleStdout`. Сам ответ при этом не терялся бы даже так — он остаётся в `buffer`
    /// (`handleStdout` не трогает `extractLine()`, пока `pendingReceive == nil`, см. её
    /// докстринг) для следующего вызова `receive()` — но ТЕКУЩИЙ, уже висящий вызов получил бы
    /// отказ вместо ответа, который на самом деле уже есть или вот-вот придёт.
    func handleTermination(status: Int32) {
        recordTermination(ProcessRPCTransportError(description: "процесс плагина завершился, код \(status)"))
    }

    /// Часть «процесса больше нет», общая для ОБОИХ сигналов, — фиксирует `terminated` (быстрый
    /// путь ТОЛЬКО `send()`: тому неважно, вычитан ли stdout, только факт, что писать уже
    /// некуда) и снимает `waitForExit()` в `close()`: тому важен только факт выхода процесса, не
    /// то, вычитан ли ещё stdout. Не трогает `pendingReceive`/`stdoutClosed`/`stdoutContinuation`
    /// — этими тремя ведает только `markGone`, вызываемый исключительно из настоящего EOF
    /// `stdout` (`handleStdout`), когда буфер гарантированно вычитан весь (возврат РП, приёмка
    /// PR #138, MEE-424, п. 1: `receive()` проверяет именно `stdoutClosed`, не `terminated`, —
    /// иначе уже записанный, но ещё не разобранный ответ плагина терялся бы для ЕЩЁ НЕ начатого
    /// вызова `receive()`, тем же классом гонки, что и для уже висящего). Смерть процесса БЕЗ
    /// EOF (на практике не должна случаться после `closeParentSideOfPipes` — ребёнок держит
    /// единственную оставшуюся копию конца канала) НЕ отказывает зависший `receive()` вообще —
    /// ни через этот метод, ни через сторож `waitForExit` (тот снимает только `pendingExits`,
    /// нужные `close()`, и никогда не трогает `pendingReceive`): в этом (не наблюдавшемся на
    /// практике) случае `receive()` остаётся висеть, пока вызывающая сторона сама не отменит
    /// задачу (`withTaskCancellationHandler` в `receive()`) — например, если stdout держит открытым
    /// не сам плагин, а его собственный внук-процесс, унаследовавший дескриптор. Идемпотентна:
    /// `markGone` тоже зовёт её первым делом, повторный вызов видит уже пустые
    /// `pendingExits`/уже выставленный `terminated`.
    func recordTermination(_ error: ProcessRPCTransportError) {
        if terminated == nil { terminated = error }
        for continuation in pendingExits { continuation.resume() }
        pendingExits.removeAll()
    }

    /// Точка «процесса больше нет» ТОЛЬКО от настоящего EOF `stdout` (`handleStdout`) — здесь,
    /// и только здесь, безопасно отказывать `pendingReceive` И ставить `stdoutClosed` (проверяет
    /// `receive()`, не `terminated`, — см. докстринг `recordTermination`): буфер stdout к этому
    /// моменту гарантированно вычитан весь, начиная с самого начала (порядок кусков —
    /// `AsyncStream` с одним потребителем), так что никакой ещё не разобранный ответ потеряться
    /// не может.
    func markGone(_ error: ProcessRPCTransportError) {
        recordTermination(error)
        if stdoutClosed == nil { stdoutClosed = error }
        failPendingReceive(error)
        // Без этого потребитель `stdoutStream` (единственный, `init`) навсегда завис бы на
        // следующей итерации `for await` — ни `readabilityHandler` (уже снят), ни что-либо
        // ещё больше не даст ему элемент, а `finish()` никто до этого места не звал.
        stdoutContinuation.finish()
    }

    func failPendingReceive(_ error: Error) {
        guard let continuation = pendingReceive else { return }
        pendingReceive = nil
        continuation.resume(throwing: error)
    }

    /// Сторож — конечная подстраховка на случай, если ни EOF `stdout`, ни `terminationHandler`
    /// не сработают на конкретной платформе (не политика тайм-аутов «Поведения», см. докстринг
    /// `close()`): без него `close()` рисковал бы зависнуть навсегда, если оба сигнала
    /// почему-то молчат. `timeoutSeconds` короче для грейс-периода после EOF `stdin` (`close()`
    /// даёт процессу шанс выйти самому, не по сигналу, прежде чем переходить к SIGTERM) — 5с
    /// там был бы просто потраченным временем, если процесс не собирается выходить по EOF.
    func waitForExit(timeoutSeconds: Double = 5) async {
        if !process.isRunning { return }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            // `try?` глотает `CancellationError` молча — без проверки `isCancelled` эта задача
            // звала бы `forceResolveExits()` СРАЗУ после отмены (`watchdog.cancel()` ниже), даже
            // если реальный сигнал разрешил ожидание за миллисекунды: безобидно само по себе
            // (`pendingExits` уже пуст к этому моменту), но неверно по смыслу — эта задача не
            // «сторож сработал», а отменённый и без того ничего не значащий довесок.
            guard !Task.isCancelled else { return }
            await self?.forceResolveExits()
        }
        await withCheckedContinuation { continuation in
            pendingExits.append(continuation)
        }
        watchdog.cancel()
    }

    func forceResolveExits() {
        for continuation in pendingExits { continuation.resume() }
        pendingExits.removeAll()
    }
}
