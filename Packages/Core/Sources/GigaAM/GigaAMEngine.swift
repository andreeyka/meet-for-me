//  GigaAMEngine — `TranscriptionEngine` для роли ASR-ru: нарезка, распознавание, сборка `Transcript`.
//
//  Модуль: gigaam · Владелец: DEV-2 · Слой: движок
//
//  Запись любой длины даёт один `Transcript` (C-011 инвариант 19): дорожка читается потоково
//  окнами до 30 с, `ChunkCutter` выбирает место разреза, каждый кусок идёт в `GigaAMRecognizer`,
//  `TokenAssembler` собирает слова и сегменты, `ClusterAssignment` назначает кластер (инвариант 18).
//  Каналы обрабатываются один за другим, каждый своим потоком кусков.

import DomainCore
import EngineKit
import Foundation

public final class GigaAMEngine: TranscriptionEngine {

    public static let engineId = "gigaam-sherpa-onnx"
    /// Файлы модели в `ModelBundle.directoryURL` (имена локальные, `files[].name` каталога, C-014).
    public static let modelFileName = "model.int8.onnx"
    public static let tokensFileName = "tokens.txt"

    static let language = "ru"

    private let audioSource: any GigaAMAudioSource
    private let recognizerFactory: any GigaAMRecognizerFactory
    private let clock: @Sendable () -> Date

    public init(
        audioSource: any GigaAMAudioSource,
        recognizerFactory: any GigaAMRecognizerFactory,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audioSource = audioSource
        self.recognizerFactory = recognizerFactory
        self.clock = clock
    }

    public var engineId: String { Self.engineId }

    public func supportedLanguages() -> [String] { [Self.language] }

    public func transcribe(
        _ request: TranscriptionRequest,
        progress: @Sendable @escaping (EngineProgress) -> Void
    ) async throws -> Transcript {
        let recordingId = try requireSingleRecording(request.audio)
        try requireLanguage(request.language)
        try requireModelFiles(request.asrModel)
        let recognizer = try makeRecognizer(request.asrModel)
        progress(.started(stage: .asr))
        let drafts = try recognizeAll(request.audio, with: recognizer, progress: progress)
        let transcript = try buildTranscript(drafts, request: request, recordingId: recordingId)
        progress(.finished(stage: .asr))
        return transcript
    }

    // MARK: - Проверки входа

    /// Инвариант 2: все `audio` относятся к одной записи. Пустой `audio` — нет `recordingId` для результата.
    private func requireSingleRecording(_ audio: [AudioRef]) throws -> UUID {
        guard let first = audio.first else {
            throw EngineError.unsupportedRequest(message: "audio пуст: нет записи для распознавания")
        }
        guard audio.allSatisfy({ $0.recordingId == first.recordingId }) else {
            throw EngineError.unsupportedRequest(message: "audio ссылается на разные recordingId")
        }
        return first.recordingId
    }

    /// Инвариант 12: `nil` и `ru` принимаются, остальное — `unsupportedLanguage`.
    private func requireLanguage(_ language: String?) throws {
        guard let language, language != Self.language else { return }
        throw EngineError.unsupportedLanguage(language)
    }

    /// Файлы модели проверяются до первого чтения аудио.
    private func requireModelFiles(_ model: ModelBundle) throws {
        let manager = FileManager.default
        for name in [Self.modelFileName, Self.tokensFileName]
        where !manager.fileExists(atPath: model.directoryURL.appendingPathComponent(name).path) {
            throw EngineError.modelMissing(modelId: model.modelId, version: model.version)
        }
    }

    private func makeRecognizer(_ model: ModelBundle) throws -> any GigaAMRecognizer {
        do {
            return try recognizerFactory.makeRecognizer(modelDirectory: model.directoryURL)
        } catch GigaAMRecognizerError.modelFilesMissing {
            throw EngineError.modelMissing(modelId: model.modelId, version: model.version)
        } catch {
            throw Self.engineError(from: error)
        }
    }

    // MARK: - Нарезка и распознавание

    private func recognizeAll(
        _ audio: [AudioRef], with recognizer: any GigaAMRecognizer,
        progress: @Sendable @escaping (EngineProgress) -> Void
    ) throws -> [OrderedDraft] {
        let durations = try audio.map { ref in try translated { try audioSource.durationMs(of: ref) } }
        var tracker = ProgressTracker(totalMs: durations.reduce(0, +), report: progress)
        var drafts: [OrderedDraft] = []
        for (order, ref) in audio.enumerated() {
            let channelDrafts = try recognizeChannel(
                ref, durationMs: durations[order], recognizer: recognizer, tracker: &tracker
            )
            let base = drafts.count
            drafts += channelDrafts.enumerated().map {
                OrderedDraft(segment: $1, channelOrder: order, sequence: base + $0)
            }
        }
        return drafts
    }

    private func recognizeChannel(
        _ audio: AudioRef, durationMs: Int, recognizer: any GigaAMRecognizer, tracker: inout ProgressTracker
    ) throws -> [SegmentDraft] {
        var drafts: [SegmentDraft] = []
        var positionMs = 0
        while positionMs < durationMs {
            try Self.checkCancelled()
            let endMs = min(positionMs + ChunkCutter.maxChunkMs, durationMs)
            let window = try translated { try audioSource.read(audio, fromMs: positionMs, toMs: endMs) }
            let length = ChunkCutter.cutLength(window: window, isLast: endMs == durationMs)
            let chunkMs = length * 1_000 / ChunkCutter.sampleRate
            guard chunkMs > 0 else { break }
            let chunk = try translated { try recognizer.recognize(samples: Array(window.prefix(length))) }
            try Self.checkCancelled()
            drafts += try translated {
                try TokenAssembler.assemble(
                    chunk, shiftMs: positionMs + audio.offsetMs, chunkDurationMs: chunkMs, channel: audio.channel
                )
            }
            positionMs += chunkMs
            tracker.advance(byMs: chunkMs)
        }
        return drafts
    }

    // MARK: - Сборка результата

    /// Сегменты обоих каналов — по неубыванию `startMs`, при равенстве — в порядке `request.audio`.
    private func buildTranscript(
        _ drafts: [OrderedDraft], request: TranscriptionRequest, recordingId: UUID
    ) throws -> Transcript {
        let ordered = drafts.sorted {
            ($0.segment.startMs, $0.channelOrder, $0.sequence) < ($1.segment.startMs, $1.channelOrder, $1.sequence)
        }.map(\.segment)
        do {
            let clusters = try ClusterAssignment.assign(ordered)
            let segments = try zip(ordered, clusters.clusters).map {
                try $0.makeSegment(cluster: $1, wantWordTimestamps: request.wantWordTimestamps)
            }
            return try Transcript(
                recordingId: recordingId, language: Self.language, engine: Self.engineId,
                modelVersion: request.asrModel.version, createdAt: clock(),
                segments: segments, speakers: clusters.speakers
            )
        } catch let error as DomainValidationError {
            throw EngineError.invalidResult(error)
        }
    }

    // MARK: - Ошибки

    private struct OrderedDraft {
        let segment: SegmentDraft
        let channelOrder: Int
        let sequence: Int
    }

    private struct ProgressTracker {
        let totalMs: Int
        let report: @Sendable (EngineProgress) -> Void
        private var doneMs = 0

        init(totalMs: Int, report: @escaping @Sendable (EngineProgress) -> Void) {
            self.totalMs = totalMs
            self.report = report
        }

        /// Доля обработанных мс по всем каналам; не убывает и не выходит за 1.
        mutating func advance(byMs: Int) {
            doneMs += byMs
            let fraction = totalMs > 0 ? min(1, Double(doneMs) / Double(totalMs)) : 1
            report(.advanced(stage: .asr, fraction: fraction))
        }
    }

    private static func checkCancelled() throws {
        if Task.isCancelled { throw EngineError.cancelled }
    }

    /// Ошибки источника и распознавателя: `EngineError` (в том числе `audioUnreadable` и
    /// `unsupportedRequest`, инвариант 17) проходит как есть, прочее — `runtimeFailure`.
    private func translated<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch {
            throw Self.engineError(from: error)
        }
    }

    private static func engineError(from error: Error) -> EngineError {
        switch error {
        case let known as EngineError:
            return known
        case is CancellationError:
            return .cancelled
        case GigaAMRecognizerError.runtimeFailure(let message):
            return .runtimeFailure(message: message)
        case GigaAMRecognizerError.modelFilesMissing:
            return .runtimeFailure(message: "файлы модели исчезли во время работы")
        default:
            return .runtimeFailure(message: "\(error)")
        }
    }
}
