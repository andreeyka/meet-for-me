//  SherpaGigaAMRecognizerTests — MEE-503 (Z5 решения IR-152, MEE-486): адаптер `GigaAMSherpa`.
//
//  Модуль: gigaam · Владелец: DEV-2
//
//  Без модели (везде, включая CI): критерий 4 — нет файла модели → `modelFilesMissing`, которую
//  `GigaAMEngine` сводит к `modelMissing` (это сведение проверяет `GigaAMEngineTests` в Packages/Core).
//  С моделью (только Mac РП): критерии 2 и 3 — `SherpaGigaAMRecognizerModelTests`.

import Foundation
import GigaAM
@testable import GigaAMSherpa
import XCTest

final class SherpaGigaAMRecognizerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GigaAMSherpaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // Критерий 4
    func testEmptyDirectoryIsModelFilesMissing() {
        assertModelFilesMissing()
    }

    func testMissingModelFileIsModelFilesMissing() throws {
        try Data("▁ 0\n".utf8).write(to: file(SherpaGigaAMRecognizerFactory.tokensFileName))
        assertModelFilesMissing()
    }

    func testMissingTokensFileIsModelFilesMissing() throws {
        try Data([0]).write(to: file(SherpaGigaAMRecognizerFactory.modelFileName))
        assertModelFilesMissing()
    }

    func testDirectoryInPlaceOfModelFileIsModelFilesMissing() throws {
        try FileManager.default.createDirectory(
            at: file(SherpaGigaAMRecognizerFactory.modelFileName), withIntermediateDirectories: false
        )
        try Data("▁ 0\n".utf8).write(to: file(SherpaGigaAMRecognizerFactory.tokensFileName))
        assertModelFilesMissing()
    }

    func testMissingDirectoryIsModelFilesMissing() {
        directory = directory.appendingPathComponent("нет-такого")
        assertModelFilesMissing()
    }

    func testFileNamesMatchEngine() {
        XCTAssertEqual(SherpaGigaAMRecognizerFactory.modelFileName, GigaAMEngine.modelFileName)
        XCTAssertEqual(SherpaGigaAMRecognizerFactory.tokensFileName, GigaAMEngine.tokensFileName)
    }

    // Порт обещает `▁` в начале слова; sherpa-onnx отдаёт на его месте пробел.
    func testPortTokenRestoresWordMarker() {
        XCTAssertEqual(SherpaGigaAMRecognizer.portToken(" при"), "▁при")
        XCTAssertEqual(SherpaGigaAMRecognizer.portToken(" "), "▁")
        XCTAssertEqual(SherpaGigaAMRecognizer.portToken("вет"), "вет")
        XCTAssertEqual(SherpaGigaAMRecognizer.portToken("."), ".")
        XCTAssertEqual(SherpaGigaAMRecognizer.portToken(""), "")
    }

    private func file(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func assertModelFilesMissing(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(
            try SherpaGigaAMRecognizerFactory().makeRecognizer(modelDirectory: directory), file: file, line: line
        ) { error in
            XCTAssertEqual(error as? GigaAMRecognizerError, .modelFilesMissing, file: file, line: line)
        }
    }
}
