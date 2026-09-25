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
/// манифеста (К53) и рукопожатия `initialize` (К1, следующая часть MEE-386): совпадение
/// `MAJOR` обязательно, `MINOR` — нет (§1.1/§7). Строка без точки или с нечисловым `MAJOR`
/// не совместима — решение этой задачи, контракт этот случай отдельно не разбирает.
enum RPCProtocolVersion {
    static func majorIsCompatible(_ version: String, supportedMajor: Int) -> Bool {
        guard let majorText = version.split(separator: ".", maxSplits: 1).first,
              let major = Int(majorText) else {
            return false
        }
        return major == supportedMajor
    }
}
