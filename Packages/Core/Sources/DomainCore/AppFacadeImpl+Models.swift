//  AppFacadeImpl — команды моделей и профилей, группа М плана MEE-410 (C-016 v10, MEE-25;
//  К35, вектор 4 К33, строки `models.*` К27 перечня MEE-401; задача MEE-420).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧТО НАЗВАНО КОНТРАКТОМ.
//   • §4 «Команды моделей и профилей» — сквозные обёртки над `ModelCatalogPort` (C-014):
//     фасад «вызывает порты… и публикует события» (§«Поведение»), решений не принимает.
//   • Инв. 19, §3.1: отказ каталога — `AppFacadeError.underlying` с кодом
//     `models.<имя case>`; ни один случай `ModelCatalogError` не вызван состоянием
//     системного права — `permissionKind` всюду `nil` (инв. 23).
//   • Инв. 15: команда, изменившая данные, публикует `modelsChanged` до возврата.
//
//  ЧТО КОНТРАКТ НЕ НАЗЫВАЕТ, И КАК ЭТО РЕШЕНО ЗДЕСЬ (вопросы — в отчёте MEE-420).
//   • `saveProfile`/`deleteProfile`: инв. 15 перечисляет пять событий, отдельного
//     «профили изменились» среди них нет. Профили — часть того же каталога C-014
//     (`ModelCatalogEvent.profilesChanged` у порта), поэтому публикуется `modelsChanged`.
//   • `downloadModel`, закончившийся отказом (в т.ч. `models.cancelled` после
//     `cancelModelDownload`), тоже меняет данные — состояние модели (`error`, `paused`,
//     `available`); `modelsChanged` публикуется и на успехе, и на отказе. `deleteModel` и
//     команды профилей, отказав, ничего не меняют — событие только на успехе.

import Foundation

extension AppFacadeImpl {

    // MARK: - Команды моделей и профилей (группа М)

    public func downloadModel(id: String, version: String) async throws {
        do {
            try await modelCatalog.download(id: id, version: version)
            publish(.modelsChanged)
        } catch {
            publish(.modelsChanged)
            throw wrapCatalogFailure(error)
        }
    }

    public func deleteModel(id: String, version: String) async throws {
        do {
            try await modelCatalog.delete(id: id, version: version)
        } catch {
            throw wrapCatalogFailure(error)
        }
        publish(.modelsChanged)
    }

    public func saveProfile(_ profile: TranscriptionProfile) async throws {
        do {
            try await modelCatalog.saveProfile(profile)
        } catch {
            throw wrapCatalogFailure(error)
        }
        publish(.modelsChanged)
    }

    public func deleteProfile(id: String) async throws {
        do {
            try await modelCatalog.deleteProfile(id: id)
        } catch {
            throw wrapCatalogFailure(error)
        }
        publish(.modelsChanged)
    }

    // MARK: - `models.*` (§3.1, строка `ModelCatalogError`)

    /// Любой отказ порта каталога: `ModelCatalogError` — по словарю, прочее — `app.internalError`.
    func wrapCatalogFailure(_ error: Error) -> AppFacadeError {
        if let catalogError = error as? ModelCatalogError {
            return wrap(catalogError)
        }
        return wrapUnexpected(error)
    }

    /// `models.<имя case>` — имя случая берётся из самого значения правилом §3.1
    /// («имя `case` как есть, без ассоциированных значений»), тем же приёмом, что
    /// `wrap(_: CaptureError)`: тринадцать случаев отдельным `switch` дали бы сложность выше
    /// порога SwiftLint, а правило и так тотально по построению. `permissionKind` — `nil`.
    func wrap(_ error: ModelCatalogError) -> AppFacadeError {
        .underlying(Self.ruleView(prefix: "models", error: error))
    }

    /// `<префикс>.<имя case>` из `String(describing:)` значения перечисления: всё до первой
    /// скобки ассоциированных значений. `permissionKind` — `nil` (для источников, у которых ни
    /// один случай не вызван состоянием системного права, инв. 23).
    static func ruleView(prefix: String, error: Error) -> AppErrorView {
        let description = String(describing: error)
        let name = description.split(separator: "(", maxSplits: 1).first.map(String.init) ?? description
        return AppErrorView(
            code: "\(prefix).\(name)", message: description, recoverySuggestion: nil, permissionKind: nil
        )
    }
}
