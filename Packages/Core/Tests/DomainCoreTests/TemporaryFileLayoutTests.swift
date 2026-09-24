//  MEE-320: `DomainTestKit.TemporaryFileLayout` — C-010 §«Фейк для тестов», К49.
//
//  К49 дословно: «Вход: `DomainTestKit.TemporaryFileLayout` в теле теста, создающего
//  каталог записи и файлы в нём. Ответ: `root` указывает на каталог во временной
//  директории, а не в `~/Library/Application Support`; после завершения теста каталога не
//  существует — ни при успехе, ни при падении теста.»
//
//  ДВЕ ПОЛОВИНЫ ОТВЕТА — ДВА ВЕКТОРА. «Ни при успехе» проверяет обычный выход из области
//  видимости (`do {}`-блок, `XCTFail` внутри которого не прерывает функцию и потому не
//  меняет этот путь). «Ни при падении» моделируется выходом из функции через `throw`:
//  второй и единственный другой способ, которым тестовая функция заканчивается раньше
//  своего конца, — и по тому же доводу, что в шапке `TemporaryFileLayout.swift`,
//  деинициализация локальной константы происходит на обоих путях одинаково.

import XCTest
import DomainCore
import DomainTestKit

final class TemporaryFileLayoutTests: XCTestCase {

    // MARK: - `root` — временная директория, не Application Support

    func test_mee320_temporaryFileLayout_rootIsUnderTemporaryDirectory() {
        let temp = TemporaryFileLayout()
        let root = temp.layout.root

        let systemTemp = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().path
        XCTAssertTrue(
            root.resolvingSymlinksInPath().path.hasPrefix(systemTemp),
            "root лежит под системной временной директорией: \(root.path)"
        )
        XCTAssertFalse(
            root.path.contains("Library/Application Support"),
            "root не указывает в Application Support"
        )
    }

    // MARK: - Создание каталога записи и файлов в нём (К49, «создающего каталог и файлы»)

    func test_mee320_temporaryFileLayout_supportsCreatingRecordingDirectoryAndFiles() throws {
        let temp = TemporaryFileLayout()
        let layout = temp.layout
        let directoryName = UUID().uuidString

        try FileManager.default.createDirectory(
            at: layout.recordingDirectory(directoryName), withIntermediateDirectories: true
        )
        try Data("manifest".utf8).write(to: layout.manifestURL(directoryName))
        try Data("transcript".utf8).write(to: layout.transcriptURL(directoryName, index: 1))

        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.manifestURL(directoryName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.transcriptURL(directoryName, index: 1).path))
    }

    // MARK: - Уборка — ни при успехе, ни при падении

    func test_mee320_temporaryFileLayout_removesDirectoryAfterNormalScopeExit() throws {
        var capturedRoot: URL?
        do {
            let temp = TemporaryFileLayout()
            capturedRoot = temp.layout.root
            let root = try XCTUnwrap(capturedRoot)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.path), "вектор непустоты: каталог создан"
            )
        }
        let root = try XCTUnwrap(capturedRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "каталог убран после успеха")
    }

    func test_mee320_temporaryFileLayout_removesDirectoryWhenScopeExitsByThrow() throws {
        struct Probe: Error {}
        var capturedRoot: URL?

        func makeThenThrow() throws {
            let temp = TemporaryFileLayout()
            capturedRoot = temp.layout.root
            throw Probe()
        }

        XCTAssertThrowsError(try makeThenThrow())
        let root = try XCTUnwrap(capturedRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "каталог убран и при падении")
    }
}
