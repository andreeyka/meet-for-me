//  Манифест плагина (`plugin.json`, C-006 §7) — К52 (разбор байт тем же декодером, что
//  кадры) и К53 (сравнение schemaVersion/protocolVersion). Разбор БАЙТ, не файла: источник
//  байт (чтение с диска) — реальный процесс-транспорт, вне зоны перечня MEE-347.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import DomainCore

enum RPCHostVersioning {
    /// Единственная поддерживаемая версия схемы манифеста — сравнение на равенство (§7).
    static let pluginManifestSchemaVersion = 1

    /// `MAJOR` протокола, который умеет говорить этот хост — сравнение по совместимости с
    /// `protocolVersion` манифеста (К53) и рукопожатием `initialize` (К1, MEE-386 следующая
    /// часть — та же форма сравнения, `RPCProtocolVersion.majorIsCompatible`).
    static let supportedProtocolMajor = 1
}

struct PluginManifest: Decodable {
    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let protocolVersion: String
    let executable: String
    let args: [String]
    let networkHosts: [String]
    let hostServices: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, version, protocolVersion, executable, args, networkHosts, hostServices
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decodeBounded(Int.self, forKey: .schemaVersion)
        id = try box.decode(String.self, forKey: .id)
        name = try box.decode(String.self, forKey: .name)
        version = try box.decode(String.self, forKey: .version)
        protocolVersion = try box.decode(String.self, forKey: .protocolVersion)
        executable = try box.decode(String.self, forKey: .executable)
        args = try box.decodeIfPresent([String].self, forKey: .args) ?? []
        networkHosts = try box.decodeIfPresent([String].self, forKey: .networkHosts) ?? []
        hostServices = try box.decodeIfPresent([String].self, forKey: .hostServices) ?? []
    }
}

enum PluginManifestError: Error, Equatable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case incompatibleProtocolMajor(found: String, supportedMajor: Int)
}

enum PluginManifestLoader {
    /// К52: разбор целиком тем же путём, что кадры (`DomainJSON.decode`) — повторяющийся
    /// ключ отвергает манифест целиком тем же `DecodingError.dataCorrupted`, что и кадр
    /// (К48 вход В); неизвестные ключи игнорируются, форма файла при чтении свободна.
    /// К53: `schemaVersion` — точное равенство, манифест с другим значением отвергается
    /// целиком. `protocolVersion` — та же форма сравнения, что решит К1: несовпадение
    /// `MAJOR` — плагин не запускается, не дожидаясь `initialize`.
    static func parse(_ bytes: Data) throws -> PluginManifest {
        let manifest = try DomainJSON.decode(PluginManifest.self, from: bytes)
        guard manifest.schemaVersion == RPCHostVersioning.pluginManifestSchemaVersion else {
            throw PluginManifestError.unsupportedSchemaVersion(
                found: manifest.schemaVersion, supported: RPCHostVersioning.pluginManifestSchemaVersion
            )
        }
        let supportedMajor = RPCHostVersioning.supportedProtocolMajor
        guard RPCProtocolVersion.majorIsCompatible(manifest.protocolVersion, supportedMajor: supportedMajor) else {
            throw PluginManifestError.incompatibleProtocolMajor(
                found: manifest.protocolVersion, supportedMajor: supportedMajor
            )
        }
        return manifest
    }
}

/// Сравнение `protocolVersion` (строка `MAJOR.MINOR`) по совместимости — общая форма для
/// манифеста (К53) и рукопожатия `initialize` (К1): совпадение `MAJOR` обязательно, `MINOR` —
/// нет (§1.1/§7). Форма строки — строго «цифры.цифры»: ровно одна точка, обе стороны непустые,
/// только ASCII-цифры, без ведущего нуля (кроме самого «0») — решение этой задачи, контракт
/// этот случай отдельно не разбирает. `Int(_:)` сам по себе такую форму не гарантирует: он
/// принимает ведущий `+` (`Int("+1") == 1`) и ведущие нули (`Int("01") == 1`), а старая форма
/// сравнения (`split(maxSplits: 1).first`) вовсе не требовала второй половины — строка без
/// точки проходила бы дальше просто как один `MAJOR` (возврат РП, MEE-386: `"1"`, `"+1.0"`,
/// `"01.0"`, `"1.abc"`, `"1."` — все должны отвергаться, ни один пример этой формой не проходит).
enum RPCProtocolVersion {
    static func majorIsCompatible(_ version: String, supportedMajor: Int) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let major = strictNonNegativeInteger(parts[0]),
              strictNonNegativeInteger(parts[1]) != nil else {
            return false
        }
        return major == supportedMajor
    }

    /// Непустая последовательность ASCII-цифр (`0`-`9`), без знака и без ведущего нуля, кроме
    /// самого `"0"` — `Character.isNumber` в одиночку пропустил бы и не-ASCII цифры (например,
    /// арабские), поэтому обе проверки (`isASCII`, `isNumber`) обязательны вместе.
    private static func strictNonNegativeInteger(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        guard text == "0" || text.first != "0" else {
            return nil
        }
        return Int(text)
    }
}
