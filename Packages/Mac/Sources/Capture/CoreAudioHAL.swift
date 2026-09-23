//  CoreAudioHAL — тонкие обёртки над свойствами Core Audio HAL и создание process tap.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Признак отказа по праву у `AudioHardwareCreateProcessTap` НЕ ИЗМЕРЕН НИ РАЗУ (контракт C-004,
//  «Опора на приватный API…», п. 4: «Сценарий отказа TCC не измерен ни разу — пользователь оба
//  раза нажал «Разрешить»»). Код ниже угадывает `kAudioHardwareIllegalOperationError` тем же
//  приёмом и по тому же доводу, что `Detector.HALStatusMapping` — единственный код TCC-отказа,
//  который спайк вообще наблюдал у Core Audio (там же, для перечисления процессов, а не для
//  tap). Признак измеряется вручную критерием М1 (перечень MEE-310); до замера доверия к нему
//  нет, и любой другой ненулевой код читается как `systemUnavailable`, а не как отказ права —
//  так реализация не выдаёт молчаливую догадку за наблюдённый факт (правило 16 `docs/process.md`).

import AudioToolbox
import CoreAudio
import Darwin
import DomainCore
import Foundation

enum TapCreationOutcome: Sendable {
    case success(AudioObjectID)
    case permissionDenied
    case failure(String)
}

private func halAddress(
    _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

enum HALObject {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func processObject(pid: Int32) -> AudioObjectID? {
        var address = halAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<Int32>.size),
                                                &qualifier, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func devices() -> [AudioObjectID] {
        var address = halAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = halAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func defaultInputDevice() -> AudioObjectID? {
        var address = halAddress(kAudioHardwarePropertyDefaultInputDevice)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &value)
        return status == noErr && value != kAudioObjectUnknown ? value : nil
    }

    static func resolveInputDevice(_ selection: InputSelection) -> (id: AudioObjectID, uid: String?, name: String?)? {
        switch selection {
        case .systemDefault:
            guard let id = defaultInputDevice() else { return nil }
            return (id, string(id, kAudioDevicePropertyDeviceUID), string(id, kAudioObjectPropertyName))
        case .uid(let uid):
            guard let id = devices().first(where: { string($0, kAudioDevicePropertyDeviceUID) == uid })
            else { return nil }
            return (id, uid, string(id, kAudioObjectPropertyName))
        case .none:
            return nil
        }
    }

    static func inputChannelCount(_ object: AudioObjectID) -> Int {
        var address = halAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }.first ?? 0
    }
}

enum HALTap {
    /// Признак отказа по праву — догадка, см. шапку файла. До десяти попыток на `noErr` с
    /// нулевым id (замер спайка MEE-8: такая комбинация случалась при смене формата — новый
    /// UUID и короткая пауза чинили её за счёт спайка).
    static func create(for processes: [AudioObjectID]) -> TapCreationOutcome {
        var attempt = 0
        while attempt < 10 {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.uuid = UUID()
            description.name = "meetforme-capture"
            description.muteBehavior = .unmuted
            description.isPrivate = true
            var tapID = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(description, &tapID)
            if status == permissionDeniedStatus { return .permissionDenied }
            guard status == noErr else { return .failure(halMessage(status)) }
            if tapID != kAudioObjectUnknown { return .success(tapID) }
            attempt += 1
            usleep(100_000)
        }
        return .failure("AudioHardwareCreateProcessTap вернул id 0 \(attempt) раз подряд")
    }

    static func describedProcesses(_ tapObject: AudioObjectID) -> [CaptureProcessDescriptor] {
        var address = halAddress(kAudioTapPropertyDescription)
        var value: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(tapObject, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let description = value?.takeRetainedValue() else { return [] }
        return description.processes.compactMap { object in
            guard let pid = HALObject.pid(of: object) else { return nil }
            let bundleId = HALObject.string(object, kAudioProcessPropertyBundleID)
            return CaptureProcessDescriptor(pid: pid, bundleId: (bundleId?.isEmpty ?? true) ? nil : bundleId,
                                           executableName: HALObject.executableName(pid: pid))
        }
    }

    /// Догадка признака отказа по праву (см. шапку файла): единственный код, который спайк
    /// вообще наблюдал у Core Audio для отказа TCC (при перечислении процессов).
    private static let permissionDeniedStatus = Int32(kAudioHardwareIllegalOperationError)

    private static func halMessage(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        let code = bytes.allSatisfy { (32..<127).contains($0) } ? (String(bytes: bytes, encoding: .ascii) ?? "") : ""
        return "OSStatus \(status)" + (code.isEmpty ? "" : " (\(code))")
    }
}

extension HALObject {
    static func pid(of object: AudioObjectID) -> Int32? {
        var address = halAddress(kAudioProcessPropertyPID)
        var value = Int32(0)
        var size = UInt32(MemoryLayout<Int32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func executableName(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
