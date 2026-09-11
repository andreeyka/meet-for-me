import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// Тонкие обёртки над свойствами Core Audio HAL. Только то, что нужно спайку.

struct HALError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    var description: String { "\(what): OSStatus \(status) (\(fourCC(UInt32(bitPattern: status))))" }
}

func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(value) }
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
}

func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else { throw HALError(status: status, what: what()) }
}

func propertyAddress(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func hostTimeSeconds(_ host: UInt64) -> Double { Double(AudioConvertHostTimeToNanos(host)) / 1e9 }
func nowHost() -> UInt64 { AudioGetCurrentHostTime() }

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var address = propertyAddress(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
                  "get '\(fourCC(selector))' of object \(object)")
        return value
    }

    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, zero: T) throws -> [T] {
        var address = propertyAddress(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "size '\(fourCC(selector))'")
        var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        if values.isEmpty { return [] }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values), "get '\(fourCC(selector))'")
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = propertyAddress(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let string = value else { return nil }
        return string.takeRetainedValue() as String
    }

    // MARK: устройства

    static func devices() -> [AudioObjectID] {
        (try? getArray(system, kAudioHardwarePropertyDevices, zero: AudioObjectID(0))) ?? []
    }

    static func defaultInput() -> AudioObjectID? {
        let id = (try? get(system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0))) ?? 0
        return id == kAudioObjectUnknown ? nil : id
    }

    static func defaultOutput() -> AudioObjectID? {
        let id = (try? get(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))) ?? 0
        return id == kAudioObjectUnknown ? nil : id
    }

    static func device(uid: String) -> AudioObjectID? {
        devices().first { deviceUID($0) == uid }
    }

    static func deviceUID(_ id: AudioObjectID) -> String? { getString(id, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ id: AudioObjectID) -> String? { getString(id, kAudioObjectPropertyName) }

    static func nominalRate(_ id: AudioObjectID) -> Double {
        (try? get(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
    }

    static func actualRate(_ id: AudioObjectID) -> Double {
        (try? get(id, kAudioDevicePropertyActualSampleRate, initial: Float64(0))) ?? 0
    }

    static func transport(_ id: AudioObjectID) -> String {
        let value = (try? get(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
        return fourCC(value)
    }

    static func isAlive(_ id: AudioObjectID) -> Bool {
        ((try? get(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) ?? 0) != 0
    }

    /// Число каналов в каждом потоке устройства в заданном направлении.
    static func streamChannels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Задержки устройства в кадрах: (устройство, safety offset, первый поток, размер буфера).
    static func latency(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [String: UInt32] {
        var result: [String: UInt32] = [:]
        result["device"] = try? get(id, kAudioDevicePropertyLatency, scope: scope, initial: UInt32(0))
        result["safety"] = try? get(id, kAudioDevicePropertySafetyOffset, scope: scope, initial: UInt32(0))
        result["buffer"] = try? get(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))
        if let streams = try? getArray(id, kAudioDevicePropertyStreams, scope: scope, zero: AudioObjectID(0)),
           let first = streams.first {
            result["stream"] = try? get(first, kAudioStreamPropertyLatency, initial: UInt32(0))
        }
        return result
    }

    static func describeDevice(_ id: AudioObjectID) -> [String: Any] {
        [
            "id": id,
            "uid": deviceUID(id) ?? "?",
            "name": deviceName(id) ?? "?",
            "transport": transport(id),
            "inputChannels": streamChannels(id, scope: kAudioObjectPropertyScopeInput),
            "outputChannels": streamChannels(id, scope: kAudioObjectPropertyScopeOutput),
            "nominalRate": nominalRate(id),
        ]
    }

    // MARK: процессы

    static func processObjects() -> [AudioObjectID] {
        (try? getArray(system, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0))) ?? []
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let path: String?
    let parentPID: pid_t
    let responsiblePID: pid_t
    let isRunning: Bool
    let isRunningInput: Bool
    let isRunningOutput: Bool

    var executableName: String? { path.map { URL(fileURLWithPath: $0).lastPathComponent } }

    init(object: AudioObjectID) {
        self.object = object
        pid = (try? HAL.get(object, kAudioProcessPropertyPID, initial: pid_t(-1))) ?? -1
        bundleID = HAL.getString(object, kAudioProcessPropertyBundleID)
        path = ProcessTools.path(pid)
        parentPID = ProcessTools.parent(pid)
        responsiblePID = ProcessTools.responsible(pid)
        isRunning = ((try? HAL.get(object, kAudioProcessPropertyIsRunning, initial: UInt32(0))) ?? 0) != 0
        isRunningInput = ((try? HAL.get(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) ?? 0) != 0
        isRunningOutput = ((try? HAL.get(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
    }

    static func all() -> [AudioProcess] { HAL.processObjects().map(AudioProcess.init(object:)) }
}

enum ProcessTools {
    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    static func parent(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        return sysctl(&mib, 4, &info, &size, nil, 0) == 0 && size > 0 ? info.kp_eproc.e_ppid : -1
    }

    // Приватный символ libquarantine/libsystem: «ответственный» процесс (тот, к кому TCC относит права).
    // Только для наблюдения в спайке: публичного API нет.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    static func responsible(_ pid: pid_t) -> pid_t { responsibleFn?(pid) ?? -1 }

    static func bundleIdentifier(ofPath path: String?) -> String? {
        guard var url = path.map({ URL(fileURLWithPath: $0) }) else { return nil }
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if ["app", "xpc", "appex"].contains(url.pathExtension) { return Bundle(url: url)?.bundleIdentifier }
        }
        return nil
    }
}
