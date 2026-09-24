//  withDeadline — предел ожидания для тестовых сигналов `await*` (MEE-374, возврат РП
//  24.09 18:05): `TestSupport.swift` уже стоял у порога `file_length` SwiftLint (400 строк),
//  добавление сюда увело бы файл за предел — отдельный файл здесь по объёму, не по смыслу.

import Foundation
import XCTest

/// Резюмирует continuation ровно один раз — второй вызов игнорируется. Тот же приём, что
/// `ResumeOnce` продакшена (`CapturePromptRace.swift`).
private final class DeadlineOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(completed: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: completed)
    }
}

/// Ограничивает `operation` пределом `seconds` — тем же приёмом, что уже устоялся в этом
/// дереве для гонки исхода против таймаута (`race()`, `CapturePromptRace.swift`): `withTaskGroup`
/// здесь не годится — выход из его области ждёт ВСЕ дочерние задачи, а не только первую
/// готовую, и завис бы вместе с незавершённым ожиданием. Bare `Task`, гонка вручную через
/// continuation, оба исхода `cancel()`ятся симметрично. Новые сигналы `await*` этого дерева
/// обязаны падать `XCTFail`, а не висеть до сторожа CI.
func withDeadline(
    _ seconds: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ operation: @escaping @Sendable () async -> Void
) async {
    let operationTask = Task<Void, Never> { await operation() }
    let timeoutTask = Task<Void, Never> {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    defer {
        operationTask.cancel()
        timeoutTask.cancel()
    }
    let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let once = DeadlineOutcome(continuation)
        Task {
            await operationTask.value
            once.resume(completed: true)
        }
        Task {
            await timeoutTask.value
            once.resume(completed: false)
        }
    }
    if !completed {
        XCTFail("превышен предел ожидания \(seconds) с", file: file, line: line)
    }
}
