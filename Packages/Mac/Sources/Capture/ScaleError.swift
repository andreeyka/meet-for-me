//  ScaleError — формула C-004 §«Оценка ошибки шкалы», инвариант 10.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  scaleErrorMs(d) = max(floor(d.reason), ceil(|fileMinusHostMs| на момент разрыва))
//
//  Таблица floor — дословно из контракта: `.rebuild`/`.sleep`/`.sourceGone` → 150
//  (`AudioCaptureLimits.scaleErrorFloorMs`), `.dropped`/`.truncated` → 0. Значение меньше floor
//  не пишется никогда, даже если измерение дало меньше, — floor выражает неустановленную
//  причину, а не результат измерения (контракт, дословно).

import DomainCore
import Foundation

enum ScaleError {

    static func floorMs(for reason: RecordingManifest.DiscontinuityReason) -> Int {
        switch reason {
        case .rebuild, .sleep, .sourceGone:
            return AudioCaptureLimits.scaleErrorFloorMs
        case .dropped, .truncated, .unknown:
            return 0
        }
    }

    /// `fileMinusHostMs` — `nil`, если измерить не удалось (контракт: тогда берётся `floor`).
    /// `.truncated` — особый случай, не общее правило: «после последнего разрыва содержимого
    /// нет, и смещать нечего» — ноль безусловно, измерение сюда не подставляется (контракт,
    /// §«Оценка ошибки шкалы», дословно), даже если вызывающая сторона его всё же передаст.
    static func compute(reason: RecordingManifest.DiscontinuityReason, fileMinusHostMs: Double?) -> Int {
        guard reason != .truncated else { return 0 }
        let floor = floorMs(for: reason)
        guard let fileMinusHostMs else { return floor }
        let measured = Int(fileMinusHostMs.magnitude.rounded(.up))
        return max(floor, measured)
    }
}
