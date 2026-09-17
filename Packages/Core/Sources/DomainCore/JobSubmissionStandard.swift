//  `JobPayload.type`, `JobPayload.profileId` и `JobSubmission.standard(_:runAfter:)` —
//  контракт C-013 (MEE-21), §1 «Задача» и §4 «Значения по умолчанию».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ПОЧЕМУ ЭТОТ ФАЙЛ ЗАВЕДЁН ЧАСТЬЮ B, А НЕ ЗАДАЧЕЙ ОБ ОЧЕРЕДИ — названо, а не умолчано.
//  C-013 объявляет все три члена (§1, блок объявлений: `public var type`,
//  `public var profileId`, `public static func standard(_:runAfter:)`), а MEE-289 их
//  НЕ написал и назвал это решением: «все три — тела, а не типы» (шапка `JobQueue.swift`).
//  Критерий К63 перечня MEE-277 требует дословно: «задачи собираются
//  `JobSubmission.standard(_:runAfter:)` с `runAfter == now`». Требование без средства
//  неисполнимо; §3 правил проекта велит взять недостающее средство по конвенции и назвать
//  это строкой отчёта — что и сделано.
//
//  ЧТО ИМЕННО ВЗЯТО ПО КОНВЕНЦИИ, И ЧТО НЕ ВЗЯТО. Взято одно: тела трёх объявленных членов,
//  собранные по таблице §4 C-013 дословно. Не взято ничего сверх: ни одного нового имени,
//  ни одного значения, которого в таблице нет, — публичная поверхность `domain-core` от
//  этого файла не растёт ни на символ, потому что все три члена уже объявлены контрактом.
//
//  `JobQueue.swift` (объявления MEE-289) этим файлом НЕ тронут ни символом: расширения
//  лежат здесь, а не там.
//
//  ЦЕНА НАЗВАНА: если задача о реализации очереди напишет те же тела у себя, определений
//  станет два и они разойдутся молча. Условие снятия — задача об очереди берёт этот файл
//  себе либо заменяет его своим; до тех пор он один.

import Foundation

public extension JobPayload {

    /// Тип задачи по составу нагрузки (§1 C-013).
    var type: JobType {
        switch self {
        case .transcode:
            return .transcode
        case .transcribe:
            return .transcribe
        case .diarize:
            return .diarize
        case .attribute:
            return .attribute
        case .summarize:
            return .summarize
        }
    }

    /// `profileId` нагрузки, если она его несёт; иначе `nil`. Единственный источник
    /// значения `JobConditions.requiresProfileReady` (§4 C-013, инвариант 22).
    var profileId: String? {
        switch self {
        case .transcode, .attribute:
            return nil
        case let .transcribe(_, profileId, _):
            return profileId
        case let .diarize(_, profileId):
            return profileId
        case let .summarize(_, _, profileId):
            return profileId
        }
    }
}

public extension JobSubmission {

    /// Значения по умолчанию из таблицы §4 C-013 для типа полезной нагрузки.
    ///
    /// `dedupKey` таблицей §4 не задаётся ни одному типу и остаётся `nil`: колонки у него
    /// в таблице нет, а придумывать ключ здесь значило бы завести правило, которого у
    /// контракта нет. Пределы `maxConcurrent` — свойство очереди, а не подачи, и в
    /// `JobSubmission` поля под них нет ни одного.
    static func standard(_ payload: JobPayload, runAfter: Date) -> JobSubmission {
        let defaults = JobTypeDefaults.of(payload.type)
        return JobSubmission(
            payload: payload,
            priority: defaults.priority,
            maxAttempts: defaults.maxAttempts,
            runAfter: runAfter,
            conditions: JobConditions(
                requiresACPower: defaults.requiresACPower,
                forbidWhileRecording: defaults.forbidWhileRecording,
                maxThermalPressure: defaults.maxThermalPressure,
                requiresProfileReady: payload.profileId
            ),
            dedupKey: nil
        )
    }
}

/// Строка таблицы §4 C-013. Внутримодульный тип: наружу он не выходит ни одним членом,
/// и публичной поверхности не расширяет.
struct JobTypeDefaults {

    let priority: Int
    let maxAttempts: Int
    let requiresACPower: Bool
    let forbidWhileRecording: Bool
    let maxThermalPressure: ThermalPressure

    /// Таблица §4 дословно. Перебор по `JobType` тотален: добавленный шестой тип
    /// красит компиляцию, а не молча получает чужие значения.
    static func of(_ type: JobType) -> JobTypeDefaults {
        switch type {
        case .transcode:
            return JobTypeDefaults(
                priority: 50, maxAttempts: 3, requiresACPower: false,
                forbidWhileRecording: true, maxThermalPressure: .serious
            )
        case .transcribe:
            return JobTypeDefaults(
                priority: 30, maxAttempts: 3, requiresACPower: false,
                forbidWhileRecording: true, maxThermalPressure: .fair
            )
        case .diarize:
            return JobTypeDefaults(
                priority: 20, maxAttempts: 3, requiresACPower: false,
                forbidWhileRecording: true, maxThermalPressure: .fair
            )
        case .attribute:
            return JobTypeDefaults(
                priority: 40, maxAttempts: 3, requiresACPower: false,
                forbidWhileRecording: false, maxThermalPressure: .serious
            )
        case .summarize:
            return JobTypeDefaults(
                priority: 10, maxAttempts: 2, requiresACPower: true,
                forbidWhileRecording: true, maxThermalPressure: .fair
            )
        }
    }
}
