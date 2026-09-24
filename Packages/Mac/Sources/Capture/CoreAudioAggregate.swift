//  AggregateRuntime — одна сборка aggregate device: маршрутизация буферов, слушатели.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Раскладка буферов IO — по спайку: сперва входные потоки саб-устройств по порядку списка
//  (микрофон, если есть), затем taps.
//
// СТРОКА: IR-114 (MEE-332), возврат MEE-317 (третий круг) — самокоррекция. Инвариант 6,
//  C-004 v5, дословно: «включается при каждой сборке aggregate device, и выключить её нечем».
//  Прежняя запись здесь («включена ВСЕГДА, кроме единственного опорного элемента») приписывала
//  контракту оговорку про опорный элемент, которой в тексте нет, — придуманная цитата. Ниже
//  (`buildComposition`) опорный элемент (микрофон, либо выход по умолчанию без микрофона)
//  держит `kAudioSubDeviceDriftCompensationKey: 0` БЕЗУСЛОВНО, независимо от `driftCompensation`.
//  Вилка, вынесенная архитектору (IR-114), не решена мной:
//  (а) это не нарушение инварианта 6 — компенсация опорного элемента относительно самого себя
//      физического смысла не имеет (обычная практика Core Audio для master clock), и «выключить
//      нечем» относится к элементам, для которых дрейф вообще определён;
//  (б) инвариант 6 в буквальном тексте не делает для опорного элемента исключения вовсе, и
//      текущая реализация ему не соответствует — нужна другая раскладка aggregate или правка
//      контракта.
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

/// Одна регистрация `AudioObjectAddPropertyListenerBlock` — снимается тем же трио аргументов.
private struct ListenerRegistration {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}

final class AggregateRuntime: @unchecked Sendable {

    let tapObject: AudioObjectID?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listeners: [ListenerRegistration] = []
    private var isTornDown = false
    private let onBuffer: @Sendable (HardwareBuffer) -> Void
    private let onEvent: @Sendable (HardwareEvent) -> Void

    private init(
        tapObject: AudioObjectID?,
        onBuffer: @escaping @Sendable (HardwareBuffer) -> Void,
        onEvent: @escaping @Sendable (HardwareEvent) -> Void
    ) {
        self.tapObject = tapObject
        self.onBuffer = onBuffer
        self.onEvent = onEvent
    }

    static func build(
        tapObject: AudioObjectID?, microphoneUID: String?, driftCompensation: Bool,
        onBuffer: @escaping @Sendable (HardwareBuffer) -> Void, onEvent: @escaping @Sendable (HardwareEvent) -> Void
    ) throws -> AggregateRuntime {
        let runtime = AggregateRuntime(tapObject: tapObject, onBuffer: onBuffer, onEvent: onEvent)
        try runtime.assemble(microphoneUID: microphoneUID, driftCompensation: driftCompensation)
        return runtime
    }

    /// Возврат MEE-317 (четвёртый круг): видимость поднята с `private` до `internal` — `Composition`
    /// теперь возвращает и тестируемая чистая функция `assembleComposition` (см. ниже), а тесту
    /// нужно читать поля результата.
    struct Composition {
        var subDevices: [[String: Any]] = []
        var tapList: [[String: Any]] = []
        var mainUID: String?
    }

    private struct Routes {
        let mic: (index: Int, channels: Int)?
        let tap: (index: Int, channels: Int)?
    }

    private func assemble(microphoneUID: String?, driftCompensation: Bool) throws {
        let composition = buildComposition(microphoneUID: microphoneUID, driftCompensation: driftCompensation)
        aggregateID = try createAggregateDevice(composition)
        let routes = resolveRoutes(microphoneUID: microphoneUID, composition: composition)
        try installIO(microphoneRoute: routes.mic, tapRoute: routes.tap)
        installAggregateListeners()
        try startIO()
    }

    // Состав саб-устройств и tap-ов: микрофон (или, без него, выход по умолчанию — только ради
    // часов, см. шапку файла) плюс единственный tap этого сеанса. Поиск устройств через HAL —
    // здесь (`HALObject.devices()`, `HALTap.uid(of:)`); сама сборка словаря из уже готовых UID —
    // в чистой `assembleComposition` ниже (возврат MEE-317, четвёртый круг: прежде обе части были
    // слиты в одной нетестируемой функции — тест мог проверить только константу `0`/`1`, которую
    // порт сам же передавал, ни разу не пройдя через код, реально складывающий словарь).
    private func buildComposition(microphoneUID: String?, driftCompensation: Bool) -> Composition {
        var resolvedMicrophoneUID: String?
        if let micUID = microphoneUID, let micDevice = HALObject.devices().first(where: {
            HALObject.string($0, kAudioDevicePropertyDeviceUID) == micUID
        }) {
            resolvedMicrophoneUID = micUID
            installMicrophoneListeners(micDevice)
        }
        let defaultOutputUID = resolvedMicrophoneUID == nil ? HALObject.defaultOutputForClock() : nil
        let tapUID = tapObject.flatMap(HALTap.uid(of:))
        return Self.assembleComposition(microphoneUID: resolvedMicrophoneUID, defaultOutputUID: defaultOutputUID,
                                        tapUID: tapUID, driftCompensation: driftCompensation)
    }

    /// Сборка HAL-словаря из ГОТОВЫХ UID — чистая функция, ни одного обращения к HAL (поиск
    /// устройств и tap-а остаётся в `buildComposition` выше). Возврат MEE-317 (четвёртый круг):
    /// тестируется напрямую в CI без TCC и живого звука — у каждого элемента, кроме опорного
    /// (первого назначенного `mainUID`), `drift` обязан быть `nonReferenceDriftCompensationValue`,
    /// у самого опорного — `0` безусловно (см. `// СТРОКА: IR-114` в шапке файла).
    ///
    /// `driftCompensation` доходит до HAL-словаря буквально (`kAudioSubTapDriftCompensationKey`) —
    /// возврат MEE-317 (второй круг): аргумент раньше не участвовал в сборке вовсе.
    static func assembleComposition(
        microphoneUID: String?, defaultOutputUID: String?, tapUID: String?, driftCompensation: Bool
    ) -> Composition {
        var result = Composition()
        if let microphoneUID {
            result.subDevices.append([kAudioSubDeviceUIDKey: microphoneUID, kAudioSubDeviceDriftCompensationKey: 0])
            result.mainUID = microphoneUID
        } else if let defaultOutputUID {
            result.subDevices.append([kAudioSubDeviceUIDKey: defaultOutputUID, kAudioSubDeviceDriftCompensationKey: 0])
            result.mainUID = defaultOutputUID
        }
        if let tapUID {
            let tapIsReference = result.mainUID == nil
            let compensationValue = 0 // ВРЕМЕННЫЙ БАГ для проверки красноты теста, не мёржить
            result.tapList.append([kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: compensationValue])
            if tapIsReference { result.mainUID = tapUID }
        }
        return result
    }

    /// Значение `kAudioSubTapDriftCompensationKey` для НЕ опорного tap — чистая функция без
    /// живого HAL, тестируемая напрямую (возврат MEE-317, третий круг: `buildComposition` целиком
    /// не тестируема в CI без TCC и настоящего tap-объекта, эта часть её решения — тестируема).
    static func nonReferenceDriftCompensationValue(_ driftCompensation: Bool) -> Int {
        driftCompensation ? 1 : 0
    }

    private func createAggregateDevice(_ composition: Composition) throws -> AudioObjectID {
        var dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetForMe capture",
            kAudioAggregateDeviceUIDKey: "meetforme-capture-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: composition.subDevices,
            kAudioAggregateDeviceTapListKey: composition.tapList
        ]
        if let mainUID = composition.mainUID { dictionary[kAudioAggregateDeviceMainSubDeviceKey] = mainUID }

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &newAggregateID)
        guard status == noErr else {
            throw NSError(domain: "CoreAudioGateway", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "AudioHardwareCreateAggregateDevice: \(status)"])
        }
        return newAggregateID
    }

    /// Раскладка буферов IO (шапка файла): сперва входной поток микрофона, если он вошёл в
    /// состав, затем tap — оба индекса считаются от накопленного смещения.
    private func resolveRoutes(microphoneUID: String?, composition: Composition) -> Routes {
        var index = 0
        var micRoute: (index: Int, channels: Int)?
        if let micUID = composition.mainUID, microphoneUID != nil,
           composition.subDevices.contains(where: { $0[kAudioSubDeviceUIDKey] as? String == micUID }) {
            let device = HALObject.devices().first { HALObject.string($0, kAudioDevicePropertyDeviceUID) == micUID }
            let channels = device.map(HALObject.inputChannelCount) ?? 0
            if channels > 0 { micRoute = (index, channels) }
            index += channels
        }
        var tapRoute: (index: Int, channels: Int)?
        if let tapObject {
            tapRoute = (index, HALTap.channelCount(of: tapObject))
        }
        return Routes(mic: micRoute, tap: tapRoute)
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
        if status == noErr { listeners.append(ListenerRegistration(object: object, address: address, block: block)) }
    }

    func teardown() {
        isTornDown = true
        for registration in listeners {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.object, &address, nil, registration.block)
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
