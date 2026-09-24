//  TranscribeJobHandler — обработчик задачи `.transcribe` (C-012 v10 §4/§4.1, инварианты 19,
//  20, 22; MEE-394, выявлено приёмкой #111/MEE-390). Отображает исход `TranscriptionServicePort
//  .transcribe` в `JobOutcome` РОВНО по таблице §4 — обработчик не пишет своего отображения
//  (инвариант 20 дословно).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Место — здесь, не в `engine-xpc`: контракт §4 сам объясняет это разделом «Почему в C-012»
//  (граница знания принадлежит стороне, которая знает движок) — но РЕАЛИЗАЦИЯ отображения
//  физически лежит в `domain-core`, где живёт очередь-потребитель `JobHandler` (C-013).
//
//  РЕШЕНО IR-131 (MEE-397): `TranscriptionJobSpec.wantWordTimestamps`/`.diarizeSystemChannel`
//  заданы здесь `true` не заглушкой, а решением контракта — `JobPayload.transcribe` (C-013 §1)
//  умышленно не несёт эти два поля («Данные на границе», C-013), и оба всегда `true` в Срезе 1
//  по доводу, напечатанному в C-012 §1 (абзац сразу после блока кода §1). Критерии
//  К43–К45/К47 (предмет исходной задачи) их не проверяют — они проверяют ОТОБРАЖЕНИЕ уже
//  брошенной `TranscriptionServiceError`, не форму отправленного `TranscriptionJobSpec`.
//
//  Задержка `modelsNotReady` (§4.1): 300с на `attempts == 0`, 900с на любом другом значении —
//  тотально по значению поля, дословно.

import Foundation

public struct TranscribeJobHandler: JobHandler {
    public let type: JobType = .transcribe

    private let port: TranscriptionServicePort

    public init(port: TranscriptionServicePort) {
        self.port = port
    }

    public func run(
        _ job: Job,
        progress: @Sendable @escaping (Double) -> Void
    ) async -> JobOutcome {
        guard case .transcribe(let recordingId, let profileId, let language) = job.payload else {
            return .permanentFailure(error: "TranscribeJobHandler получил job.payload не .transcribe")
        }
        let spec = TranscriptionJobSpec(
            recordingId: recordingId, profileId: profileId, language: language,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
        do {
            _ = try await port.transcribe(spec) { transcriptionProgress in
                progress(transcriptionProgress.fraction)
            }
            return .success
        } catch let error as TranscriptionServiceError {
            return Self.outcome(for: error, attempts: job.attempts)
        } catch {
            return .permanentFailure(error: "\(error)")
        }
    }

    /// C-012 §4 дословно: `TranscriptionServiceError` → `JobOutcome`, одна строка — один исход.
    private static func outcome(for error: TranscriptionServiceError, attempts: Int) -> JobOutcome {
        switch error {
        case .serviceCrashed:
            return .retry(after: 30, error: "serviceCrashed")
        case .serviceUnavailable(let message):
            return .retry(after: 30, error: message)
        case .timedOut(let seconds):
            return .retry(after: 30, error: "timedOut(\(seconds))")
        case .modelsNotReady(let profileId, let message):
            return .retry(after: modelsNotReadyDelay(attempts: attempts), error: "\(profileId): \(message)")
        case .protocolVersionMismatch(let client, let service):
            return .permanentFailure(error: "protocolVersionMismatch(client: \(client), service: \(service))")
        case .messageTooLarge(let bytes):
            return .permanentFailure(error: "messageTooLarge(\(bytes))")
        case .invalidRequest(let message):
            return .permanentFailure(error: message)
        case .engineFailure(let code, let message):
            return outcomeForEngineFailure(code: code, message: message)
        case .cancelled:
            return outcomeForCancellation(message: "cancelled")
        }
    }

    /// §4.1 дословно: правило тотально по значению `job.attempts` на входе, не по тому,
    /// первый ли это фактический повтор.
    private static func modelsNotReadyDelay(attempts: Int) -> Double {
        attempts == 0 ? 300 : 900
    }

    /// Коды `engineFailure` — имена случаев `EngineError` (C-011), таблица §4 «Коды engineFailure».
    private static func outcomeForEngineFailure(code: String, message: String) -> JobOutcome {
        switch code {
        case "modelMissing", "modelIncompatible", "audioUnreadable",
             "unsupportedLanguage", "unsupportedRequest", "invalidResult":
            return .permanentFailure(error: message)
        case "outOfMemory":
            return .retry(after: 600, error: message)
        case "runtimeFailure":
            return .retry(after: 30, error: message)
        case "cancelled":
            return outcomeForCancellation(message: message)
        default:
            return .retry(after: 30, error: "неизвестный код engineFailure: \(code) (\(message))")
        }
    }

    /// §4, строка `cancelled`: `.success`, только если ОЧЕРЕДЬ сама инициировала отмену этой
    /// задачи — наблюдается отменой Task, в котором `JobQueueEngine` зовёт `run(_:progress:)`
    /// (`JobQueueEngineExecution.swift`); без отмены `cancelled` — нарушение контракта движка.
    private static func outcomeForCancellation(message: String) -> JobOutcome {
        Task.isCancelled ? .success : .permanentFailure(error: "\(message) без отмены очередью")
    }
}
