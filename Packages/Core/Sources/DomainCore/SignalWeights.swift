//  SignalWeights — значения таблицы весов C-009 и единственное место, где она читается.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  §6 называет форму сам, и здесь она исполнена буквально: чтение ресурса — одно место
//  (`current()`), построение значений из байтов — чистая функция от `Data` (`values(from:)`),
//  вызываемая тестом напрямую, а наружу выходит публичный член, отдающий ЗНАЧЕНИЯ — не путь,
//  не файловый `URL` и не `Data`. Обе применяющие стороны — порт из `detector` (инвариант 11)
//  и домен (`signalTtlSeconds` и вес календарного сигнала) — получают их отсюда одинаково.
//
//  Почему это не нарушает запрет карты модулей «никаких файловых путей»: ресурс собственного
//  собранного модуля наружу не ведёт — адрес задаёт сборка, содержимое едет одним артефактом
//  с кодом, а на границе модуля чтения не видно (§6, инвариант 23).
//
//  Однократность и неизменяемость (инвариант 22) держит `static let`: он вычисляется один раз
//  при первом обращении и больше никогда. Перечитывания нет — подменённый после этого файл
//  ресурса ответа не меняет ни на одном обращении, и второго набора значений не существует.
//
//  Битая таблица — отказ, а не умолчание (§«Поведение»): ни зажатия веса в `0...1`, ни нулей,
//  ни пустой таблицы, ни «последних удачных». Публичного почленного инициализатора у типа нет
//  намеренно: значение этого типа существует только как результат чтения годной таблицы.
//
//  Чисел §5 в этом файле нет ни одного — ни срока актуальности, ни веса календарного сигнала:
//  они данные, а не код (инвариант 1), и литерал здесь отменил бы смысл переезда таблицы.

import Foundation

/// Значения таблицы весов (§5), прочитанные один раз и неизменные в течение жизни процесса.
public struct SignalWeights: Equatable, Sendable {

    /// Версия схемы прочитанной таблицы.
    public let schemaVersion: Int
    /// Срок актуальности сигнала в секундах; строго больше нуля, иначе таблица битая.
    public let signalTtlSeconds: Int

    private let calendarWindow: Double
    private let clientRunning: Double
    private let clientAudioOutput: Double
    private let microphoneInUse: Double

    /// Вес вида сигнала. Тотальна по построению: набор весов полон, иначе значение не собралось.
    public func weight(for kind: MeetingSignalKind) -> Double {
        switch kind {
        case .calendarWindow: return calendarWindow
        case .clientRunning: return clientRunning
        case .clientAudioOutput: return clientAudioOutput
        case .microphoneInUse: return microphoneInUse
        }
    }

    /// Тот же набор отображением. Состав берётся из `MeetingSignalKind`, а не из второго списка.
    public var weights: [MeetingSignalKind: Double] {
        Dictionary(uniqueKeysWithValues: MeetingSignalKind.allCases.map { ($0, weight(for: $0)) })
    }

    // MARK: - Построение значений из байтов: чистая функция

    /// `Data` → значения. Ни ресурсов, ни файловой системы, ни времени, ни состояния системы.
    public static func values(from data: Data) throws -> SignalWeights {
        try SignalWeights(table: DomainJSON.decode(SignalWeightsTable.self, from: data))
    }

    private init(table: SignalWeightsTable) throws {
        guard table.signalTtlSeconds > 0 else {
            throw SignalWeights.broken(["signalTtlSeconds"],
                                       "неположительный signalTtlSeconds: правило актуальности "
                                       + "не действует ни на одном входе")
        }
        guard Set(table.weights.keys) == Set(MeetingSignalKind.allCases.map(\.rawValue)) else {
            throw SignalWeights.broken(["weights"],
                                       "набор ключей weights не равен набору видов сигнала")
        }
        schemaVersion = table.schemaVersion
        signalTtlSeconds = table.signalTtlSeconds
        calendarWindow = try SignalWeights.weight(.calendarWindow, in: table)
        clientRunning = try SignalWeights.weight(.clientRunning, in: table)
        clientAudioOutput = try SignalWeights.weight(.clientAudioOutput, in: table)
        microphoneInUse = try SignalWeights.weight(.microphoneInUse, in: table)
    }

    private static func weight(_ kind: MeetingSignalKind, in table: SignalWeightsTable) throws -> Double {
        guard let value = table.weights[kind.rawValue] else {
            throw broken(["weights", kind.rawValue], "веса этого вида сигнала в таблице нет")
        }
        guard (0...1).contains(value) else {
            throw broken(["weights", kind.rawValue],
                         "вес вне 0...1: инвариант 11 объявляет такой сигнал невалидным")
        }
        return value
    }

    /// Отказ на битой таблице. Ключ назван в `codingPath` — тем же способом, каким отказывает
    /// разбор: `DomainValidatable`-типов у C-009 нет, и `DomainValidationError` здесь не бросает никто.
    private static func broken(_ path: [String], _ reason: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: path.map { WeightKey(stringValue: $0) },
            debugDescription: reason))
    }

    // MARK: - Чтение ресурса собственного собранного модуля: одно место

    /// Публичный член, отдающий прочитанные значения таблицы весов.
    ///
    /// Читает ресурс один раз за жизнь процесса (инвариант 22). На битой таблице бросает и
    /// не отдаёт значений ни одной применяющей стороне — ни сейчас, ни при следующем обращении.
    public static func current() throws -> SignalWeights {
        try loaded.get()
    }

    /// Единственное место в модуле, где читается файл-ресурс.
    private static let loaded = Result<SignalWeights, Error> { try values(from: resourceBytes()) }

    private static func resourceBytes() throws -> Data {
        guard let url = Bundle.module.url(forResource: "signal-weights", withExtension: "json") else {
            throw broken(["signal-weights.json"], "ресурс не положен сборкой модуля domain-core")
        }
        return try Data(contentsOf: url)
    }
}
