//  AggregateRuntime — одна сборка aggregate device: маршрутизация буферов, слушатели.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Раскладка буферов IO — по спайку: сперва входные потоки саб-устройств по порядку списка
//  (микрофон, если есть), затем taps. Компенсация дрейфа включена на каждом саб-устройстве и
//  тапе, кроме первого — первый служит опорными часами (инвариант 6: включена ВСЕГДА, кроме
//  единственного опорного элемента, без которого дрейфу не от чего считаться).
//
//  Слушатель формата стоит на МИКРОФОНЕ, не на aggregate (инвариант 5, дословно измерено
//  спайком: «на самом aggregate слушатель конфигурации потоков не сработал ни разу»).
//  Инвалидацию tap эта реализация отдельно не различает от гибели aggregate (см. `teardown`
//  ниже и `onEvent(.aggregateDied)`) — это НЕ измерено ни спайком, ни ручным прогоном, и точная
//  реакция HAL на смерть конкретно tap, а не всего aggregate, остаётся риском реализации до
//  первого ручного похода к Mac; реакция порта на `.tapInvalidated` при этом полностью
//  реализована и проверена швом теста (`AudioCaptureImplHardwareEvents`) — риск локализован в
//  этом одном файле, а не размазан по модулю.

import AudioToolbox
import CoreAudio
import Foundation

final class AggregateRuntime: @unchecked Sendable {

    let tapObject: AudioObjectID?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var isTornDown = false
    private let onBuffer: @Sendable (HardwareBuffer) -> Void
    private let onEvent: @Sendable (HardwareEvent) -> Void

    private init(tapObject: AudioObjectID?, onBuffer: @escaping @Sendable (HardwareBuffer) -> Void,
                onEvent: @escaping @Sendable (HardwareEvent) -> Void) {
        self.tapObject = tapObject
        self.onBuffer = onBuffer
        self.onEvent = onEvent
    }

    static func build(
        tapObject: AudioObjectID?, microphoneUID: String?,
        onBuffer: @escaping @Sendable (HardwareBuffer) -> Void, onEvent: @escaping @Sendable (HardwareEvent) -> Void
    ) throws -> AggregateRuntime {
        let runtime = AggregateRuntime(tapObject: tapObject, onBuffer: onBuffer, onEvent: onEvent)
        try runtime.assemble(microphoneUID: microphoneUID)
        return runtime
    }

    private func assemble(microphoneUID: String?) throws {
        var subDevices: [[String: Any]] = []
        var mainUID: String?
        var micRoute: (index: Int, channels: Int)?

        if let micUID = microphoneUID, let micDevice = HALObject.devices().first(where: {
            HALObject.string($0, kAudioDevicePropertyDeviceUID) == micUID
        }) {
            subDevices.append([kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: 0])
            mainUID = micUID
            installMicrophoneListeners(micDevice)
        } else if let output = HALObject.defaultOutputForClock() {
            subDevices.append([kAudioSubDeviceUIDKey: output, kAudioSubDeviceDriftCompensationKey: 0])
            mainUID = output
        }

        var tapList: [[String: Any]] = []
        var tapUID: String?
        if let tapObject, let uid = HALTap.uid(of: tapObject) {
            tapUID = uid
            tapList.append([kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: mainUID == nil ? 0 : 1])
            if mainUID == nil { mainUID = uid }
        }

        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetForMe capture",
            kAudioAggregateDeviceUIDKey: "meetforme-capture-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        if let mainUID { composition[kAudioAggregateDeviceMainSubDeviceKey] = mainUID }

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID)
        guard status == noErr else {
            throw NSError(domain: "CoreAudioGateway", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "AudioHardwareCreateAggregateDevice: \(status)"])
        }
        aggregateID = newAggregateID

        var index = 0
        if let micUID = mainUID, subDevices.contains(where: { $0[kAudioSubDeviceUIDKey] as? String == micUID }),
           microphoneUID != nil {
            let device = HALObject.devices().first { HALObject.string($0, kAudioDevicePropertyDeviceUID) == micUID }
            let channels = device.map(HALObject.inputChannelCount) ?? 0
            if channels > 0 { micRoute = (index, channels) }
            index += channels > 0 ? channels : 0
        }
        var tapRoute: (index: Int, channels: Int)?
        if let tapObject {
            let channels = HALTap.channelCount(of: tapObject)
            tapRoute = (index, channels)
        }

        try installIO(microphoneRoute: micRoute, tapRoute: tapRoute)
        installAggregateListeners()
        try startIO()
        _ = tapUID
    }

    private func installIO(
        microphoneRoute: (index: Int, channels: Int)?, tapRoute: (index: Int, channels: Int)?
    ) throws {
        let onBuffer = self.onBuffer
        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, nil
        ) { [weak self] _, input, inputTime, _, _ in
            guard self != nil else { return }
            let hostTimeMs = Self.milliseconds(fromHostTime: inputTime.pointee.mHostTime)
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            for (slot, route) in [(HardwareBuffer.Slot.mic, microphoneRoute), (.system, tapRoute)] {
                guard let route, route.index < list.count else { continue }
                let buffer = list[route.index]
                guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                let samples = Int(buffer.mDataByteSize) / 4
                let pointer = data.assumingMemoryBound(to: Float.self)
                onBuffer(HardwareBuffer(slot: slot, samples: Array(UnsafeBufferPointer(start: pointer, count: samples)),
                                        frameCount: samples / Int(buffer.mNumberChannels),
                                        channelCount: Int(buffer.mNumberChannels), hostTime: hostTimeMs))
            }
        }
        guard status == noErr else {
            throw NSError(domain: "CoreAudioGateway", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "AudioDeviceCreateIOProcIDWithBlock: \(status)"])
        }
        procID = newProcID
    }

    private func startIO() throws {
        guard let procID else { return }
        let status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            throw NSError(domain: "CoreAudioGateway", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "AudioDeviceStart: \(status)"])
        }
    }

    private func installAggregateListeners() {
        addListener(aggregateID, kAudioDevicePropertyDeviceIsAlive) { [onEvent] in
            if !HALObject.isAlive(self.aggregateID) {
                onEvent(.aggregateDied(atHostTime: Self.milliseconds(fromHostTime: mach_absolute_time())))
            }
        }
    }

    private func installMicrophoneListeners(_ mic: AudioObjectID) {
        addListener(mic, kAudioDevicePropertyDeviceIsAlive) { [onEvent] in
            guard !HALObject.isAlive(mic) else { return }
            onEvent(.microphoneChanged(nil, atHostTime: Self.milliseconds(fromHostTime: mach_absolute_time())))
        }
        addListener(mic, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput) { [onEvent] in
            let channels = HALObject.inputChannelCount(mic)
            onEvent(.microphoneFormatChanged(channelCount: channels,
                                             atHostTime: Self.milliseconds(fromHostTime: mach_absolute_time())))
        }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             _ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                  mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.isTornDown else { return }
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, nil, block)
        if status == noErr { listeners.append((object, address, block)) }
    }

    func teardown() {
        isTornDown = true
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, nil, block)
        }
        listeners = []
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        // tap НЕ уничтожается здесь: он принадлежит сеансу и переживает пересборку (инвариант 4).
    }

    private static func milliseconds(fromHostTime hostTime: UInt64) -> UInt64 {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return hostTime }
        return hostTime * UInt64(info.numer) / UInt64(info.denom) / 1_000_000
    }
}

extension HALObject {
    static func isAlive(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : false
    }

    static func defaultOutputForClock() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(HALObject.system, &address, 0, nil, &size, &value)
        guard status == noErr, value != kAudioObjectUnknown else { return nil }
        return string(value, kAudioDevicePropertyDeviceUID)
    }
}

extension HALTap {
    static func uid(of tapObject: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(tapObject, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let description = value?.takeRetainedValue() else { return nil }
        return description.uuid.uuidString
    }

    static func channelCount(of tapObject: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapObject, &address, 0, nil, &size, &format)
        return status == noErr ? Int(format.mChannelsPerFrame) : 0
    }
}
