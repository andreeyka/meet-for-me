//  HALProcessSource — сырой снимок аудиопроцессов из Core Audio HAL. Единственное место модуля,
//  которое говорит с системой о процессах.
//
//  Измерено спайком MEE-8 (R1) на macOS 26.6: список `kAudioHardwarePropertyProcessObjectList`
//  вместе с флагами приходит процессу без права на запись системного звука; у процесса без
//  бандла `kAudioProcessPropertyBundleID` — пустая строка. На 14.x не проверено.
//
//  Каждый код возврата проходит одно отображение `HALStatusMapping` (шов Ш3). Исключение одно и
//  названо: `kAudioHardwareBadObjectError` у отдельного процесса значит, что процесс ушёл между
//  чтением списка и чтением его свойств, — смерть процесса не ошибка (§«Поведение»), и запись
//  просто не попадает в снимок.

import CoreAudio
import Darwin
import DomainCore
import Foundation

/// Снятый снимок: содержание и момент, на который содержание верно.
///
/// Шов Ш4, свойства (i) и (ii): вход наблюдения — пара «содержание + момент». Момент здесь есть
/// значение входа, а не показание часов наблюдения, и разводится он с ними тестом. Без этой пары
/// момент снимка и момент публикации в `SignalEngine` были одной переменной, а К51 и К62
/// сверяли её саму с собой.
struct TakenSnapshot: Equatable, Sendable {
    let content: RawSnapshot
    let observedAt: Date
}

/// Источник снимков процессов. Шов Ш4 (i) и (ii): в тесте его заменяет значение.
protocol ProcessSnapshotSource: Sendable {
    func readSnapshot() throws -> TakenSnapshot
}

final class HALProcessSource: ProcessSnapshotSource, @unchecked Sendable {

    /// Часы, которыми источник помечает снимок. Момент снимается ДО чтения списка процессов:
    /// содержание верно на момент не раньше него, а публикация случается заведомо позже — то
    /// есть в живой работе `observedAt` меньше момента публикации, а не равен ему.
    private let clock: ObservationClock

    /// Журнал кодов возврата каждого системного вызова; ведётся, только если передан.
    private let journal: StatusJournal?

    init(clock: ObservationClock = SystemClock(), journal: StatusJournal? = nil) {
        self.clock = clock
        self.journal = journal
    }

    func readSnapshot() throws -> TakenSnapshot {
        let observedAt = clock.now()
        var records: [RawProcessRecord] = []
        for object in try processObjects() {
            if case .value(let record) = try record(of: object) {
                records.append(record)
            }
        }
        var bundleIds: [Int32: String] = [:]
        for pid in Set(records.compactMap(\.responsiblePid)) {
            bundleIds[pid] = ProcessIdentity.bundleIdentifier(ofPid: pid)
        }
        return TakenSnapshot(content: RawSnapshot(records: records, bundleIdsByPid: bundleIds),
                             observedAt: observedAt)
    }

    // MARK: - Список процессов

    private func processObjects() throws -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try require(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size),
                    call: "process list size", data: .systemAudioRecording)
        let stride = MemoryLayout<AudioObjectID>.stride
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        guard !objects.isEmpty else { return [] }
        try require(AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects),
                    call: "process list", data: .systemAudioRecording)
        return Array(objects.prefix(Int(size) / stride))
    }

    // MARK: - Одна запись

    private func record(of object: AudioObjectID) throws -> Reading<RawProcessRecord> {
        guard case .value(let pid) = try scalar(object, kAudioProcessPropertyPID, Int32(0),
                                                data: .systemAudioRecording),
              case .value(let output) = try scalar(object, kAudioProcessPropertyIsRunningOutput, UInt32(0),
                                                   data: .systemAudioRecording),
              case .value(let input) = try scalar(object, kAudioProcessPropertyIsRunningInput, UInt32(0),
                                                  data: .microphone),
              case .value(let bundle) = try bundleId(of: object) else { return .processGone }
        return .value(RawProcessRecord(pid: pid,
                                       bundleId: bundle,
                                       responsiblePid: ProcessIdentity.responsiblePid(of: pid),
                                       executableName: ProcessIdentity.executableName(ofPid: pid),
                                       isRunningOutput: output != 0,
                                       isRunningInput: input != 0))
    }

    private func scalar<Value: FixedWidthInteger>(_ object: AudioObjectID,
                                                  _ selector: AudioObjectPropertySelector,
                                                  _ initial: Value,
                                                  data kind: PermissionKind) throws -> Reading<Value> {
        var address = Self.address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        let call = "process \(object) '\(HALStatusMapping.fourCharacterCode(Int32(bitPattern: selector)))'"
        return try accept(status, call: call, data: kind) ? .value(value) : .processGone
    }

    /// Строка bundle id как её отдал HAL, без нормализации: `""` приводит к `nil` сборка снимка.
    private func bundleId(of object: AudioObjectID) throws -> Reading<String?> {
        var address = Self.address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard try accept(status, call: "process \(object) bundle id", data: .systemAudioRecording) else {
            return .processGone
        }
        return .value(value.map { $0.takeRetainedValue() as String })
    }

    // MARK: - Коды возврата

    /// `true` — данные есть; `false` — процесс ушёл; иначе бросает то, что назвало отображение.
    private func accept(_ status: OSStatus, call: String, data kind: PermissionKind) throws -> Bool {
        journal?.record(call: call, status: status)
        if status == kAudioHardwareBadObjectError { return false }
        if let failure = HALStatusMapping.error(for: status, call: call, data: kind) { throw failure }
        return true
    }

    private func require(_ status: OSStatus, call: String, data kind: PermissionKind) throws {
        journal?.record(call: call, status: status)
        if let failure = HALStatusMapping.error(for: status, call: call, data: kind) { throw failure }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Результат чтения свойства процесса: значение либо «процесс ушёл».
enum Reading<Value> {
    case value(Value)
    case processGone
}

/// Журнал кодов возврата системных вызовов — вход критерия К56.
final class StatusJournal: @unchecked Sendable {

    struct Entry: Equatable, Sendable {
        let call: String
        let status: Int32
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(call: String, status: Int32) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(call: call, status: status))
    }

    var all: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
