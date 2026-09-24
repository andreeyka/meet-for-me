//  TemporaryFileLayout — `FileLayout`, указывающий на временный каталог, который тест
//  создаёт и удаляет за собой. C-010 §«Фейк для тестов» (К49).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  «`root` указывает на каталог во временной директории, а не в `~/Library/Application
//  Support`; после завершения теста каталога не существует — ни при успехе, ни при падении
//  теста» (К49). Удаление привязано к `deinit`, а не к явному вызову теста: локальная
//  константа выходит из области видимости в конце тестовой функции и при обычном провале
//  (`XCTFail` не прерывает функцию — тест продолжается до её конца) и при `throws`-выходе
//  (распространение ошибки Swift — не C++-исключение поверх стека, деинициализация
//  локальных значений происходит как часть обычного возврата), поэтому `deinit` срабатывает
//  в обоих названных случаях. Он не срабатывает при падении процесса целиком (`fatalError`),
//  но от этого не защищено ни одно средство `DomainTestKit`.
//
//  Класс, а не структура: `FileLayout` — `Equatable`-значение без владения ресурсом;
//  здесь владение появляется (каталог на диске), и `deinit` есть только у класса.

import Foundation
import DomainCore

/// `FileLayout`, живущий во временном каталоге, который сам за собой убирает.
public final class TemporaryFileLayout: @unchecked Sendable {

    /// `FileLayout`, чей `root` указывает во временную директорию — не в
    /// `~/Library/Application Support`.
    public let layout: FileLayout

    public init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomainTestKit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = FileLayout(root: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: layout.root)
    }
}
