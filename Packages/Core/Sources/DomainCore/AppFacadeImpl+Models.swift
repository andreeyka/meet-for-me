//  AppFacadeImpl — команды моделей и профилей, группа М плана MEE-410 (C-016 v11, MEE-25;
//  К35, К64, вектор 4 К33, строки `models.*` К27 перечня MEE-401; задачи MEE-420, MEE-465).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧТО НАЗВАНО КОНТРАКТОМ.
//   • §4 «Команды моделей и профилей» — сквозные обёртки над `ModelCatalogPort` (C-014):
//     фасад «вызывает порты… и публикует события» (§«Поведение»), решений не принимает.
//   • Инв. 19, §3.1: отказ каталога — `AppFacadeError.underlying` с кодом
//     `models.<имя case>`; ни один случай `ModelCatalogError` не вызван состоянием
//     системного права — `permissionKind` всюду `nil` (инв. 23).
//   • Инв. 15 с уточнением IR-144 (MEE-463): команда, изменившая данные, публикует
//     `modelsChanged` до возврата. Событие покрывает каталог C-014 целиком — модели и
//     профили: `saveProfile`/`deleteProfile` публикуют его. «Изменила данные» — по факту, а
//     не по исходу: `downloadModel`, отказавшая после начала загрузки, сменила состояние
//     модели (`error`, `paused`, `available`) и публикует `modelsChanged` до броска. Отказ
//     `deleteModel` (инв. 11 C-014) и отказ команд профилей ничего не меняют — событий нет.
//
//  ЧТО КОНТРАКТ НЕ НАЗЫВАЕТ, И КАК ЭТО РЕШЕНО ЗДЕСЬ.
//   • Отличить отказ `download` до начала загрузки от отказа после её начала фасад по
//     ответу порта не может; `modelsChanged` публикуется на любом отказе `downloadModel` —
//     лишнее событие безвредно (оно не несёт данных, инв. 15 и §«Поведение»), пропущенное
//     оставило бы интерфейс с устаревшим состоянием модели.

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
        .underlying(Self.ruleView(prefix: "models", error: error, message: Self.modelsMessage(error)))
    }

    /// Текст с подробностью значения там, где она что-то говорит человеку (MEE-494); иначе —
    /// текст словаря по коду (`nil`).
    private static func modelsMessage(_ error: ModelCatalogError) -> String? {
        switch error {
        case .unknownProfile(let id): return "Профиль распознавания «\(id)» не найден"
        case .notDownloaded(let modelId, _): return "Модель «\(modelId)» не загружена"
        case .modelInUse(let modelId, _): return "Модель «\(modelId)» сейчас используется"
        case .modelInUseByProfile(let modelId, let profileIds):
            let profiles = profileIds.map { "«\($0)»" }.joined(separator: ", ")
            return "Модель «\(modelId)» нужна профилям распознавания: \(profiles)"
        case .insufficientDiskSpace(let required, let available):
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "Недостаточно места на диске: нужно \(format(required)), свободно \(format(available))"
        case .unsupportedChip(let required):
            return "Модели нужен процессор Apple \(required.rawValue.uppercased()) или новее"
        case .insufficientRAM(let requiredGB):
            return "Модели нужно не меньше \(requiredGB) ГБ оперативной памяти"
        default: return nil
        }
    }

    /// `<префикс>.<имя case>` из `String(describing:)` значения перечисления: всё до первой
    /// скобки ассоциированных значений. `permissionKind` — `nil` (для источников, у которых ни
    /// один случай не вызван состоянием системного права, инв. 23).
    /// `message` — текст для человека по коду (`UnderlyingErrorText`, MEE-494) либо переданный.
    static func ruleView(prefix: String, error: Error, message: String? = nil) -> AppErrorView {
        let description = String(describing: error)
        let name = description.split(separator: "(", maxSplits: 1).first.map(String.init) ?? description
        return UnderlyingErrorText.view(code: "\(prefix).\(name)", message: message)
    }
}
