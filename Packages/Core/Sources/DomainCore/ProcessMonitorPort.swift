//  ProcessMonitorPort — контракт C-009 v2 (MEE-15), §1 «Процессы и аудиоактивность»
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-86). Реализацию порта пишет модуль `detector`
//  (Packages/Mac/Sources/Detector/), фейк `FakeProcessMonitorPort` придёт отдельным пакетом DEV-2.
//  §2 контракта (JoinInfo, правило §4.1, PlatformResolver) — в PlatformResolver.swift.
//
//  Порядок типов и порядок полей внутри типа — дословно по §1 контракта
//  (порядок значим: правило обхода C-001 §0.2 п. 9).

import Foundation

public struct AudioProcess: Codable, Equatable, Sendable {
    public let pid: Int32
    public let bundleId: String?             // собственный bundle id процесса; nil, если бандла нет
    public let responsibleBundleId: String?  // bundle id ответственного процесса; nil, если он не определён
    public let executableName: String
    public let isRunningOutput: Bool         // у процесса открыт вывод; наличия звука в выводе не означает
    public let isRunningInput: Bool          // у процесса открыт вход; наличия звука во входе не означает
    public let observedAt: Date

    public init(
        pid: Int32,
        bundleId: String?,
        responsibleBundleId: String?,
        executableName: String,
        isRunningOutput: Bool,
        isRunningInput: Bool,
        observedAt: Date
    ) {
        self.pid = pid
        self.bundleId = bundleId
        self.responsibleBundleId = responsibleBundleId
        self.executableName = executableName
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
        self.observedAt = observedAt
    }
}

public extension AudioProcess {
    /// Ключ приложения (§4.1). Чистая функция от полей записи.
    var appKey: String? { responsibleBundleId ?? bundleId }
}

/// Группа процессов одного приложения — то, что уходит в захват вместо одного pid.
public struct ProcessGroup: Codable, Equatable, Sendable {
    public let appKey: String       // ключ приложения (§4.1); непустая строка
    public let pids: [Int32]        // pid всех процессов снимка с этим appKey
    public let observedAt: Date

    public init(appKey: String, pids: [Int32], observedAt: Date) {
        self.appKey = appKey
        self.pids = pids
        self.observedAt = observedAt
    }
}

public enum MeetingSignalKind: String, Codable, Sendable, CaseIterable {
    case calendarWindow      // идёт временное окно события календаря
    case clientRunning       // запущен процесс известного клиента созвона
    case clientAudioOutput   // у процесса клиента открыт вывод звука
    case microphoneInUse     // у процесса открыт вход (микрофон)
}

public struct MeetingSignal: Codable, Equatable, Sendable {
    public let kind: MeetingSignalKind
    public let weight: Double          // 0...1, вклад сигнала; берётся из таблицы весов
    public let pid: Int32?             // процесс-источник сигнала; nil для calendarWindow
    public let bundleId: String?       // собственный bundle id процесса-источника, не ключ приложения
    public let group: ProcessGroup?    // группа приложения; см. §4.1 и «Данные на границе»
    public let provider: String?       // ключ провайдера, если он определён по ключу приложения
    public let meetingId: UUID?        // MeetingEvent.id, если сигнал привязан к событию
    public let observedAt: Date

    public init(
        kind: MeetingSignalKind,
        weight: Double,
        pid: Int32?,
        bundleId: String?,
        group: ProcessGroup?,
        provider: String?,
        meetingId: UUID?,
        observedAt: Date
    ) {
        self.kind = kind
        self.weight = weight
        self.pid = pid
        self.bundleId = bundleId
        self.group = group
        self.provider = provider
        self.meetingId = meetingId
        self.observedAt = observedAt
    }
}

public enum ProcessMonitorError: Error, Codable, Equatable, Sendable {
    case permissionRequired(PermissionKind)      // см. C-007
    case systemUnavailable(message: String)
}

public protocol ProcessMonitorPort: Sendable {
    func audioProcesses() async throws -> [AudioProcess]
    func processes(matching bundleIds: [String]) async throws -> [AudioProcess]
    func signals() -> AsyncStream<MeetingSignal>
    func startObserving() async throws
    func stopObserving() async
}
