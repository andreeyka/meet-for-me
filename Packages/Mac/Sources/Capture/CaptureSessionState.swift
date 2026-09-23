//  CaptureSessionState — изменяемое состояние одного идущего сеанса записи.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Один экземпляр живёт от успешного `start()` до `stop()`; `AudioCaptureImpl` держит его под
//  своим замком и никогда не делится им с чужим потоком напрямую — только копиями значений.

import DomainCore
import Foundation

final class CaptureSessionState {

    let recordingId: UUID
    let meetingId: UUID?
    let directory: URL
    let request: CaptureRequest
    let startedAt: Date

    var tap: TapHandle?
    var microphone: MicrophoneHandle?
    var aggregate: AggregateHandle
    var micTrack: TrackFile?
    var systemTrack: TrackFile?
    var powerToken: PowerActivityToken?
    var subscription: HardwareSubscription?

    var markers: [RecordingManifest.Marker] = []
    var discontinuities: [RecordingManifest.Discontinuity] = []
    var inputDevices: [RecordingManifest.InputDeviceSpan] = []
    var capturedProcesses: [String: RecordingManifest.CapturedProcess] = [:]
    var captureGroupKey: String?

    /// Host time первого дошедшего буфера — координата 0 опорного трека. `0` — ещё не назначен.
    var hostOrigin: UInt64 = 0
    var isPaused = false
    var pauseStartedAtMs: Int?
    var lastProcessPollHostTime: UInt64 = 0
    var currentMicrophoneUID: String?
    var currentMicrophoneName: String?
    var currentMicrophoneChannelCount: Int?
    /// Действующий выбор входа — меняется `setInput`, в отличие от `request.input` (вход
    /// исходного `start`, неизменяемый). «Следовать устройству по умолчанию» (инвариант 5,
    /// раздел «Поведение», «Смена устройства ввода») сверяется по этому полю, а не по запросу.
    lazy var currentInputSelection: InputSelection = request.input

    /// Пересборка в процессе: копится до момента, когда первый буфер новой сборки называет
    /// позицию, на которую ставится разрыв (порт «Поведение», алгоритм — как в спайке MEE-8).
    var pendingRebuild: PendingRebuild?

    struct PendingRebuild {
        let reason: RecordingManifest.DiscontinuityReason
        let atMs: Int
        let oldMicrophoneUID: String?
        let oldMicrophoneName: String?
        let requestedHostTime: UInt64
        /// Недостача файла против host time, накопленная ДО разрыва (§«Оценка ошибки шкалы»);
        /// не то же самое, что `gapMs` пересборки — это дрейф предыдущего отрезка записи.
        let fileMinusHostMs: Double
    }

    init(recordingId: UUID, meetingId: UUID?, directory: URL, request: CaptureRequest,
         startedAt: Date, aggregate: AggregateHandle) {
        self.recordingId = recordingId
        self.meetingId = meetingId
        self.directory = directory
        self.request = request
        self.startedAt = startedAt
        self.aggregate = aggregate
    }

    /// Опорный трек — микрофон, если он есть, иначе системный (та же приоритетность, что
    /// у спайка: `tracks[.mic] ?? tracks[.system]`).
    var referenceTrack: TrackFile? { micTrack ?? systemTrack }

    func track(for slot: HardwareBuffer.Slot) -> TrackFile? {
        switch slot {
        case .mic: return micTrack
        case .system: return systemTrack
        }
    }

    func manifestTracks() throws -> [RecordingManifest.Track] {
        var tracks: [RecordingManifest.Track] = []
        if let systemTrack {
            try tracks.append(.init(channel: .system, fileName: systemTrack.fileName,
                                    sampleRate: systemTrack.sampleRate,
                                    channelCount: systemTrack.channelCount, format: "pcm-caf"))
        }
        if let micTrack {
            try tracks.append(.init(channel: .mic, fileName: micTrack.fileName,
                                    sampleRate: micTrack.sampleRate,
                                    channelCount: micTrack.channelCount, format: "pcm-caf"))
        }
        return tracks
    }
}
