//  К16, К49 — C-011 инв. 13 / C-012 инв. 13 (ни один тип модуля не тянет системных
//  фреймворков; объявление `EngineTransportFault` не оборачивает `NSError`) и C-012 инв. 17
//  (`errorDomain`/коды — постоянные литералы). Способ — тот же, что `SessionMachineTextTests`
//  (DomainCoreTests): чтение исходников по пути через `#filePath`, а не через `@testable`.

import XCTest
import EngineKit

final class EngineKitSourceSurfaceTests: XCTestCase {

    private struct SourceFile {
        let name: String
        let text: String
    }

    private func sourceFiles() throws -> [SourceFile] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EngineKit")
        var files: [SourceFile] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(SourceFile(name: url.lastPathComponent,
                                    text: try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(files.isEmpty, "вектор непустоты: исходники EngineKit найдены")
        return files
    }

    // MARK: - К16 (инв. 13 C-011; инв. 13 C-012)

    func test_k16_noForbiddenFrameworkImports() throws {
        let forbidden = ["CoreML", "AVFoundation", "XPC", "NSXPCConnection", "AppKit", "ONNX", "onnxruntime"]
        let sources = try sourceFiles()
        let imports = sources.flatMap { source in
            source.text.components(separatedBy: "\n")
                .filter { $0.hasPrefix("import ") }
                .map { $0.replacingOccurrences(of: "import ", with: "") }
        }
        XCTAssertFalse(imports.isEmpty, "вектор непустоты: строки import в области есть")
        for framework in forbidden {
            XCTAssertFalse(imports.contains(framework), "«\(framework)» не импортируется")
        }
        XCTAssertEqual(Set(imports), ["DomainCore", "Foundation"],
                       "EngineKit импортирует только DomainCore и Foundation")
    }

    /// Отдельный вход и отдельный механизм (возврат РП, 24.09 14:40, п. 6): `NSError`
    /// существует и на Linux — одной сборки таргета этой строке недостаточно.
    ///
    /// Проверка — по самому ОБЪЯВЛЕНИЮ (код без строк `//`), не по всему файлу: шапка файла
    /// сама называет `NSError` по имени, объясняя, почему тип его не оборачивает (CI,
    /// прогон 36048940544, поймал именно этот случай — проверка по всему тексту красна
    /// по построению).
    func test_k16_engineTransportFaultDeclarationNeverMentionsNSError() throws {
        let sources = try sourceFiles()
        guard let file = sources.first(where: { $0.name == "EngineTransportFault.swift" }) else {
            XCTFail("EngineTransportFault.swift не найден")
            return
        }
        let code = file.text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("NSError"), "объявление EngineTransportFault не содержит NSError")
    }

    // MARK: - К49 (инв. 17)

    func test_k49_errorDomainAndCodesAreLiteralConstants() {
        XCTAssertEqual(EngineTransportFault.errorDomain, "MeetForMe.EngineTransport")
        XCTAssertEqual(EngineTransportFault.protocolVersionMismatch.rawValue, 1)
        XCTAssertEqual(EngineTransportFault.messageTooLarge.rawValue, 2)
        XCTAssertEqual(EngineTransportFault.invalidRequest.rawValue, 3)
        XCTAssertEqual(EngineTransportFault.allCases.count, 3, "ровно три кода — четвёртый (К33) вне диапазона")
    }
}
