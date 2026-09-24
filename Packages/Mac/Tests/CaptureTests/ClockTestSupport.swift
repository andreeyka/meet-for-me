//  ManualClock — шов часов теста (MEE-374, возврат РП 24.09 18:05): троттлинг `.levels`
//  (`updateLevels`) перестаёт зависеть от настоящего `Date()` и реальных пауз (см.
//  `AudioCaptureImpl.now`). Отдельный файл — `TestSupport.swift` уже стоял у порога
//  `file_length` SwiftLint (400 строк), тот же приём разведения по объёму, что и у
//  `DeadlineTestSupport.swift` рядом.

import Foundation

/// Часы под управлением теста.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 0)) {
        current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}
