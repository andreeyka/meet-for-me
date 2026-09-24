//  FakeTranscriptionEngine, FakeDiarizationEngine, FakeEmbeddingEngine, FakePostProcessor —
//  C-011 v5 «Фейк для тестов»: подставные реализации четырёх протоколов движка, публичные
//  (инвариант 23 C-012, композиция с инвариантом 15 C-011) под этими именами дословно.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения) — фейки
//
//  Отмена (К12): между `.started` и работой стоит `Task.sleep(simulatedWorkNanoseconds)` —
//  единственная точка приостановки, где кооперативная отмена реально наблюдаема; `Task.sleep`
//  сама бросает `CancellationError` при отмене во время сна, здесь заворачивается в
//  `EngineError.cancelled` (инвариант 11). Длительность мала по умолчанию, чтобы не тормозить
//  обычные прогоны, и настраиваема — тест К12 повышает её и отменяет задачу посредине.

import DomainCore
import Foundation

public final class FakeTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    public let engineId: String
    public var simulatedWorkNanoseconds: UInt64 = 1_000_000
    public var modelVersion = "fake-1.0"
    /// К1: тест подставляет результат, чей throwing-init заведомо бросает
    /// `DomainValidationError` — движок обязан поймать её и завернуть в `.invalidResult`.
    public var forcedResult: (() throws -> Transcript)?
    /// К5: «внутреннее время файла» движка — то, что он видит ДО сложения с `offsetMs`
    /// ссылки; по умолчанию 0, чтобы старое поведение (`startMs == offsetMs`) не менялось.
    public var internalSegmentStartMs: Int = 0
    /// К11: сценарий событий хода работы вместо одиночной пары `.started`/`.finished(.asr)`;
    /// `nil` — старое поведение. Заданный сценарий проигрывается целиком, и только он.
    public var progressScript: [EngineProgress]?
    /// К11: ошибка, брошенная сразу после `progressScript`, — `.finished` последнего
    /// начатого этапа при этом не проигрывается, как и было бы при настоящем сбое.
    public var failAfterScript: EngineError?

    private let lock = NSLock()
    private var languages: [String]

    public init(engineId: String = "fake-transcription", supportedLanguages: [String] = []) {
        self.engineId = engineId
        self.languages = supportedLanguages
    }

    public func supportedLanguages() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return languages
    }

    public func transcribe(
        _ request: TranscriptionRequest, progress: @Sendable @escaping (EngineProgress) -> Void
    ) async throws -> Transcript {
        try requireSameRecording(request.audio)
        try requireSupportedLanguage(request.language)
        if let progressScript {
            for event in progressScript { progress(event) }
            if let failAfterScript { throw failAfterScript }
        } else {
            progress(.started(stage: .asr))
        }
        do {
            try await Task.sleep(nanoseconds: simulatedWorkNanoseconds)
        } catch {
            throw EngineError.cancelled
        }
        do {
            let transcript = try forcedResult?() ?? makeTranscript(for: request)
            if progressScript == nil { progress(.finished(stage: .asr)) }
            return transcript
        } catch let error as DomainValidationError {
            throw EngineError.invalidResult(error)
        }
    }

    private func requireSameRecording(_ audio: [AudioRef]) throws {
        guard let first = audio.first else { return }
        guard audio.allSatisfy({ $0.recordingId == first.recordingId }) else {
            throw EngineError.unsupportedRequest(message: "audio ссылается на разные recordingId")
        }
    }

    private func requireSupportedLanguage(_ language: String?) throws {
        guard let language else { return }
        let supported = supportedLanguages()
        guard supported.isEmpty || supported.contains(language) else {
            throw EngineError.unsupportedLanguage(language)
        }
    }

    /// К5: смещение записи (`offsetMs` первой ссылки) прибавляется к внутреннему старту
    /// движка (`internalSegmentStartMs`) — итоговая позиция на общей шкале записи, не на
    /// шкале движка.
    private func makeTranscript(for request: TranscriptionRequest) throws -> Transcript {
        let base = (request.audio.first?.offsetMs ?? 0) + internalSegmentStartMs
        let recordingId = request.audio.first?.recordingId ?? UUID()
        let words = request.wantWordTimestamps
            ? [try Transcript.Word(startMs: base, endMs: base + 1_000, text: "fake",
                                   confidence: 0.9, original: nil)]
            : []
        let segment = try Transcript.Segment(
            startMs: base, endMs: base + 1_000, channel: .mic, speakerCluster: nil,
            text: "fake", textOriginal: nil, textConfidence: 0.9, words: words
        )
        return try Transcript(
            recordingId: recordingId, language: request.language ?? "en", engine: engineId,
            modelVersion: modelVersion, createdAt: Date(timeIntervalSince1970: 0),
            segments: [segment], speakers: []
        )
    }
}

public final class FakeDiarizationEngine: DiarizationEngine, @unchecked Sendable {
    public let engineId: String
    public var simulatedWorkNanoseconds: UInt64 = 1_000_000
    public var modelVersion = "fake-1.0"
    public var forcedResult: (() throws -> DiarizationResult)?

    public init(engineId: String = "fake-diarization") {
        self.engineId = engineId
    }

    /// К6: диаризация принимает только `.system` — `.mic` не о чём диаризировать
    /// (единственный говорящий и так известен, инвариант 5).
    public func diarize(
        _ request: DiarizationRequest, progress: @Sendable @escaping (EngineProgress) -> Void
    ) async throws -> DiarizationResult {
        guard request.audio.channel == .system else {
            throw EngineError.unsupportedRequest(message: "diarize принимает только канал .system")
        }
        progress(.started(stage: .diarization))
        do {
            try await Task.sleep(nanoseconds: simulatedWorkNanoseconds)
        } catch {
            throw EngineError.cancelled
        }
        do {
            let result = try forcedResult?() ?? makeResult()
            progress(.finished(stage: .diarization))
            return result
        } catch let error as DomainValidationError {
            throw EngineError.invalidResult(error)
        }
    }

    private func makeResult() throws -> DiarizationResult {
        try DiarizationResult(
            turns: [try DiarizationResult.Turn(startMs: 0, endMs: 1_000, cluster: 0)],
            speakers: [try Transcript.Speaker(cluster: 0, embedding: nil,
                                              embeddingModelVersion: nil, totalMs: 1_000)],
            modelVersion: modelVersion
        )
    }
}

public final class FakeEmbeddingEngine: EmbeddingEngine, @unchecked Sendable {
    public let engineId: String
    public let dimension: Int
    public let modelVersion: String
    public var forcedResult: (() throws -> EmbeddingResult)?

    public init(engineId: String = "fake-embedding", dimension: Int = 3, modelVersion: String = "fake-1.0") {
        self.engineId = engineId
        self.dimension = dimension
        self.modelVersion = modelVersion
    }

    public func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResult {
        do {
            return try forcedResult?() ?? EmbeddingResult(
                vector: [Float](repeating: 0.1, count: dimension), dimension: dimension,
                modelVersion: modelVersion
            )
        } catch let error as DomainValidationError {
            throw EngineError.invalidResult(error)
        }
    }
}

public final class FakePostProcessor: PostProcessor, @unchecked Sendable {
    public let engineId: String
    public var simulatedWorkNanoseconds: UInt64 = 1_000_000
    public var promptVersion = "fake-1.0"
    public var forcedResult: (() throws -> [MeetingOutputDraft])?

    public init(engineId: String = "fake-post-process") {
        self.engineId = engineId
    }

    public func process(
        _ request: PostProcessRequest, progress: @Sendable @escaping (EngineProgress) -> Void
    ) async throws -> [MeetingOutputDraft] {
        progress(.started(stage: .postProcess))
        do {
            try await Task.sleep(nanoseconds: simulatedWorkNanoseconds)
        } catch {
            throw EngineError.cancelled
        }
        do {
            let drafts = try forcedResult?() ?? [
                try MeetingOutputDraft(kind: .summary, contentMarkdown: "fake", structuredJson: nil,
                                       engine: engineId, promptVersion: promptVersion)
            ]
            progress(.finished(stage: .postProcess))
            return drafts
        } catch let error as DomainValidationError {
            throw EngineError.invalidResult(error)
        }
    }
}
