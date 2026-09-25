//  Исходники и продукт сборки таргета `Permissions` — оснастка `SymbolTableTests` (перечень
//  MEE-74, критерии 31.а, 47, 75). Разведено из `TestSupport.swift` по объёму (`file_length`),
//  не по смыслу — единственный потребитель обоих типов ниже тот же.

import Foundation

struct SourceFile {
    let name: String
    let text: String
}

enum PermissionsSources {

    static func directory(_ relative: String, from file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    static func swiftFiles(in relative: String) throws -> [SourceFile] {
        let root = directory(relative)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { name in
            SourceFile(name: name, text: try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8))
        }
    }

    static func sources() throws -> [SourceFile] { try swiftFiles(in: "Sources/Permissions") }

    /// Имя каталога объектников таргета `Permissions` РАЗНОЕ у двух систем сборки (возврат РП,
    /// локальный прогон на Swift 6.4, MEE-432): нативная зовёт его `Permissions.build`, новая —
    /// `Permissions-t.build`. Соседние каталоги `PermissionsTests-p.build` (объектники самих
    /// ТЕСТОВ — не таргета) и `Permissions-product-p.build` названы намеренно похоже и не
    /// входят в это множество: сравнение ниже — точное равенство компонента пути, не подстрока
    /// и не префикс, так что ни один из них не совпадёт ни с одним именем отсюда.
    private static let targetDirectoryNames: Set<String> = ["Permissions.build", "Permissions-t.build"]

    /// Объектные файлы таргета `Permissions`: продукт `swift build`, устойчиво к обеим системам
    /// сборки (MEE-432). Нативная кладёт `.o` рядом с бандлом тестов
    /// (`<products>/Permissions.build/*.o`); Swift 6.4 по умолчанию — глубже, в
    /// `.build/out/Intermediates.noindex/…`, путь внутри которого нигде не назван дословно.
    /// Быстрый путь (стоимость обхода всего `.build` на CI заметна) пробуется первым;
    /// рекурсивный поиск каталога из `targetDirectoryNames` от корня `.build` — только когда
    /// его не нашлось. Ни там, ни там — явный отказ (`ObjectFilesNotFoundError`), а не холостой
    /// зелёный и не невнятная системная ошибка `FileManager`.
    static func objectFiles() throws -> [URL] {
        let bundleURL = Bundle(for: FakeHoldHandle.self).bundleURL
        let nativeTarget = bundleURL.deletingLastPathComponent().appendingPathComponent("Permissions.build")
        if let fastPath = try? objectFiles(inTargetDirectory: nativeTarget), !fastPath.isEmpty {
            return fastPath.sorted { $0.path < $1.path }
        }
        guard let buildRoot = buildRoot(from: bundleURL) else {
            throw ObjectFilesNotFoundError(bundleURL: bundleURL, nativeTarget: nativeTarget, buildRoot: nil)
        }
        let found = objectFiles(recursivelyUnder: buildRoot, targetDirectoryNames: targetDirectoryNames)
        guard !found.isEmpty else {
            throw ObjectFilesNotFoundError(bundleURL: bundleURL, nativeTarget: nativeTarget, buildRoot: buildRoot)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// `.o` файлы непосредственно в каталоге таргета (нативная раскладка) — бросает, если
    /// каталога нет вовсе (Swift 6.4), и вызывающая сторона это ловит `try?`.
    private static func objectFiles(inTargetDirectory directory: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".o") }
        return names.map { directory.appendingPathComponent($0) }
    }

    /// Поднимается от бандла тестов до каталога `.build` — он есть при любой системе сборки;
    /// раскладка МЕНЯЕТСЯ внутри него, а не в том, что он существует и его можно так найти.
    private static func buildRoot(from url: URL) -> URL? {
        var current = url
        while current.pathComponents.count > 1 {
            if current.lastPathComponent == ".build" { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Рекурсивный обход `.build` в поисках `.o` внутри каталога, чьё имя — ОДНО ИЗ
    /// `targetDirectoryNames` (точным равенством компонента пути, см. докстринг множества) —
    /// Swift 6.4 вкладывает такой каталог глубже нативной раскладки (`Objects-normal/<arch>/` и
    /// промежуточные `Intermediates.noindex`), но само имя каталога зависит от системы сборки.
    private static func objectFiles(recursivelyUnder root: URL, targetDirectoryNames: Set<String>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "o" {
            let components = url.deletingLastPathComponent().pathComponents
            if components.contains(where: { targetDirectoryNames.contains($0) }) {
                found.append(url)
            }
        }
        return found
    }
}

/// Ни нативная раскладка, ни раскладка Swift 6.4 не дали ни одного объектного файла — назвать
/// обе проверенные раскладки, а не дать тесту упасть на невнятной системной ошибке или пройти
/// вхолостую на пустом массиве (MEE-432).
struct ObjectFilesNotFoundError: LocalizedError {
    let bundleURL: URL
    let nativeTarget: URL
    let buildRoot: URL?

    var errorDescription: String? {
        guard let buildRoot else {
            return "каталог .build не найден ни в одном из предков \(bundleURL.path) — "
                + "не удаётся определить корень сборки"
        }
        return "объектные файлы таргета Permissions не найдены ни в \(nativeTarget.path) (нативная раскладка), "
            + "ни рекурсивно под \(buildRoot.path) по именам каталога Permissions.build/Permissions-t.build "
            + "(раскладки нативная/Swift 6.4)"
    }
}
