//  CatalogReader — чтение `catalog.json` и `.manifest.json` (C-014 v6 §2.2; инв. 2, 3, 15, 28, 30).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  Только через `DomainJSON` (инв. 28): собственного разборщика JSON у модуля нет.
//  Любая `DecodingError` превращается в `manifestInvalid(message:)` здесь, на границе
//  чтения (§2.2); `ModelCatalogError`, брошенная из `init(from:)` (чужой `schemaVersion`),
//  проходит как есть. Инварианты 2, 3 и 30 — проверки ПОСЛЕ разбора: синтаксически такие
//  файлы валидны, `DomainJSON` их принимает (IR-139), и отказ — каталог целиком.

import Foundation
import DomainCore

enum CatalogReader {

    static func catalog(from data: Data) throws -> ModelCatalogFile {
        let file = try decode(ModelCatalogFile.self, from: data, name: "catalog.json")
        try validate(file)
        return file
    }

    static func manifest(from data: Data) throws -> ModelManifestFile {
        try decode(ModelManifestFile.self, from: data, name: ".manifest.json")
    }

    static func validate(_ file: ModelCatalogFile) throws {
        var seen = Set<String>()
        for model in file.models {
            let pair = "\(model.id)@\(model.version)"
            guard seen.insert(pair).inserted else {
                throw ModelCatalogError.manifestInvalid(
                    message: "catalog.json: повторяется модель id «\(model.id)» version «\(model.version)»")
            }
            for item in model.files where !isSHA256(item.sha256) {
                throw ModelCatalogError.manifestInvalid(
                    message: "catalog.json: модель id «\(model.id)» version «\(model.version)», "
                        + "файл «\(item.name)»: sha256 «\(item.sha256)» — не 64 символа [0-9a-f]")
            }
        }
        for profile in file.profiles where !profile.isBuiltIn {
            throw ModelCatalogError.manifestInvalid(
                message: "catalog.json: профиль «\(profile.id)» с isBuiltIn == false — каталог несёт только встроенные")
        }
    }

    static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data, name: String) throws -> Value {
        do {
            return try DomainJSON.decode(type, from: data)
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.manifestInvalid(message: "\(name): \(describe(error))")
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: error) }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "нет ключа «\(path(context.codingPath + [key]))»"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "«\(path(context.codingPath))»: \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
}
