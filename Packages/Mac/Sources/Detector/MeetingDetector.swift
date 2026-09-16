//  MeetingDetector — реализация `ProcessMonitorPort` и `PlatformResolver` (C-009).
//
//  Единственный публичный тип модуля: инвариант 21 требует хотя бы один собственный публичный
//  тип — реализации связывает composition root приложения, — и больше модулю наружу выводить
//  нечего. Публичные сигнатуры несут только позиции разрешённого списка инварианта 21.
//
//  Точка приёма значений таблицы весов (шов Ш5) — публичный инициализатор. Форма выбрана
//  решением РП (MEE-67, приёмка 12.09): отдельные параметры `Double` с метками, называющими
//  вид сигнала, — тип `SignalWeights` из `domain-core` в разрешённый список не входит, а словаря
//  контракт в нём не называет. Четвёртый параметр — срок `signalTtlSeconds`: без него порт не
//  исполнит инвариант 24 иначе как зашитой константой (шов Ш6 (ii)).
//
//  Все параметры обязательны (Ш5 (iii), первое устройство): порт без значений собрать нельзя —
//  такую реализацию не написать. Цена названа: вторая половина критерия К11 зелена по
//  построению и не доказывает ничего.
//
//  Таблицы `providers.json` и `clients.json` читаются из ресурсов модуля один раз за жизнь
//  процесса (инвариант 22). На битой таблице инициализатор бросает: объекта нет, и ни `resolve`,
//  ни `signals()` вызвать не на чем.

import DomainCore
import Foundation

/// Детектор созвона: наблюдение за аудиопроцессами и разбор ссылок на созвон.
public final class MeetingDetector: ProcessMonitorPort, PlatformResolver, Sendable {

    private let tables: RuleTables
    private let engine: SignalEngine

    /// Детектор приложения: таблицы из ресурсов модуля, процессы — из Core Audio HAL.
    ///
    /// Значения приходят от `domain-core` (`SignalWeights.current()`): три веса видов сигнала,
    /// которые публикует порт, и срок актуальности сигнала в секундах.
    public convenience init(clientRunning: Double, clientAudioOutput: Double, microphoneInUse: Double,
                            signalTtlSeconds: Double) throws {
        let values = try ReceivedValues(clientRunning: clientRunning, clientAudioOutput: clientAudioOutput,
                                        microphoneInUse: microphoneInUse, signalTtlSeconds: signalTtlSeconds)
        let environment = SignalEngine.Environment(source: HALProcessSource(), clock: SystemClock(),
                                                   driver: TimerDriver(),
                                                   preferredStep: MeetingDetector.changeObservationStep)
        self.init(tables: try RuleTables.shipped.get(), values: values, environment: environment)
    }

    init(tables: RuleTables, values: ReceivedValues, environment: SignalEngine.Environment) {
        self.tables = tables
        self.engine = SignalEngine(tables: tables, values: values, environment: environment)
    }

    /// Шаг, с которым приложение замечает появление звука, секунды. Срок подтверждения от него
    /// не зависит: шаг ограничен сверху долей `signalTtlSeconds` (`ConfirmationPolicy`).
    static let changeObservationStep: TimeInterval = 1

    // MARK: - ProcessMonitorPort

    public func audioProcesses() async throws -> [AudioProcess] {
        try engine.audioProcesses()
    }

    public func processes(matching bundleIds: [String]) async throws -> [AudioProcess] {
        SnapshotBuilder.processes(try engine.audioProcesses(), matching: bundleIds)
    }

    public func signals() -> AsyncStream<MeetingSignal> {
        engine.signals()
    }

    public func startObserving() async throws {
        try engine.startObserving()
    }

    public func stopObserving() async {
        engine.stopObserving()
    }

    // MARK: - PlatformResolver

    /// Разбор события календаря, инварианты 3 и 4. Порядок требований здесь — по §2 контракта.
    public func resolve(event: MeetingEvent) -> JoinInfo? {
        LinkResolver.resolve(event: event, tables: tables)
    }

    public func resolve(text: String, source: JoinInfo.Source) -> JoinInfo? {
        LinkResolver.resolve(text: text, source: source, tables: tables)
    }

    public func clientBundleIds(for provider: String) -> [String] {
        tables.clientBundleIds(for: provider)
    }

    public func allKnownClientBundleIds() -> [String] {
        tables.allKnownClientBundleIds()
    }

    public func provider(forAppKey appKey: String) -> String? {
        tables.provider(forAppKey: appKey)
    }

    public func isBrowser(appKey: String) -> Bool {
        tables.isBrowser(appKey: appKey)
    }

    // MARK: - Внутреннее: для тестов модуля

    var observation: SignalEngine { engine }
}
