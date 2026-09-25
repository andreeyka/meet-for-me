//  StdioProtocolTests — К52-К53 (манифест плагина, C-006 §7: разбор байт тем же декодером,
//  что кадры; schemaVersion/protocolVersion gate). Отдельный файл — тот же приём file_length/
//  type_body_length, что у соседних расширений этого же типа.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
@testable import CalendarHub

extension StdioProtocolTests {

    // MARK: - К52 (§7 — манифест, разбор байт тем же декодером, что кадры)

    func test_k52_manifestDuplicateKeyRejectedSameMechanismAsFrames() {
        let bytes = Data(#"""
        {"schemaVersion":1,"schemaVersion":1,"id":"p","name":"P","version":"1.0",
         "protocolVersion":"1.0","executable":"./p","args":[],"networkHosts":[],"hostServices":[]}
        """#.utf8)

        XCTAssertThrowsError(try PluginManifestLoader.parse(bytes))
    }

    // MARK: - К53 (§7 — schemaVersion/protocolVersion манифеста)

    func test_k53_manifestSchemaVersionMismatchRejectsWhole() {
        let bytes = Self.manifestJSON(schemaVersion: 2, protocolVersion: "1.0")
        XCTAssertThrowsError(try PluginManifestLoader.parse(bytes)) { error in
            XCTAssertEqual(error as? PluginManifestError, .unsupportedSchemaVersion(found: 2, supported: 1))
        }
    }

    func test_k53_manifestIncompatibleMajorProtocolVersionRejectsBeforeInitialize() {
        let bytes = Self.manifestJSON(schemaVersion: 1, protocolVersion: "2.0")
        XCTAssertThrowsError(try PluginManifestLoader.parse(bytes)) { error in
            XCTAssertEqual(error as? PluginManifestError, .incompatibleProtocolMajor(found: "2.0", supportedMajor: 1))
        }
    }

    func test_k53_manifestMinorVersionDifferenceIsNotFatal() throws {
        let bytes = Self.manifestJSON(schemaVersion: 1, protocolVersion: "1.9")
        let manifest = try PluginManifestLoader.parse(bytes)
        XCTAssertEqual(manifest.protocolVersion, "1.9")
    }

    static func manifestJSON(schemaVersion: Int, protocolVersion: String) -> Data {
        Data(#"""
        {"schemaVersion":\#(schemaVersion),"id":"p","name":"P","version":"1.0",
         "protocolVersion":"\#(protocolVersion)","executable":"./p","args":[],"networkHosts":[],
         "hostServices":[]}
        """#.utf8)
    }
}
