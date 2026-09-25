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
        guard mayContainDelimiter else { return }
        do {
            guard let line = try extractLine(), let continuation = pendingReceive else { return }
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

    func handleTermination(status: Int32) {
        markGone(ProcessRPCTransportError(description: "процесс плагина завершился, код \(status)"))
    }

    /// Общая точка «процесса больше нет» для обоих независимых сигналов (EOF `stdout` в
    /// `handleStdout`, `terminationHandler` в `init`) — какой бы ни сработал первым, отказывает
    /// ожидающий `receive()` и снимает `waitForExit()` в `close()`. Идемпотентна: второй сигнал
    /// (обычно оба приходят почти одновременно) видит уже пустые `pendingExits`/`pendingReceive`.
    func markGone(_ error: ProcessRPCTransportError) {
        if terminated == nil { terminated = error }
        failPendingReceive(error)
        for continuation in pendingExits { continuation.resume() }
        pendingExits.removeAll()
        // Без этого потребитель `stdoutStream` (единственный, `init`) навсегда завис бы на
        // следующей итерации `for await` — ни `readabilityHandler` (уже снят), ни что-либо
        // ещё больше не даст ему элемент, а `finish()` никто до этого места не звал. Вызов
        // безопасен повторно (документированно): какой бы из двух путей — EOF в
        // `handleStdout` или `terminationHandler` — ни позвал `markGone` первым, второй
        // застаёт уже завершённый поток.
        stdoutContinuation.finish()
    }

    func failPendingReceive(_ error: Error) {
        guard let continuation = pendingReceive else { return }
        pendingReceive = nil
        continuation.resume(throwing: error)
    }

    /// Сторож на 5 секунд — конечная подстраховка на случай, если ни EOF `stdout`, ни
    /// `terminationHandler` не сработают на конкретной платформе (не политика тайм-аутов
    /// «Поведения», см. докстринг `close()`): без него `close()` рисковал бы зависнуть
    /// навсегда, если оба сигнала почему-то молчат.
    func waitForExit() async {
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

    func forceResolveExits() {
        for continuation in pendingExits { continuation.resume() }
        pendingExits.removeAll()
    }
}
