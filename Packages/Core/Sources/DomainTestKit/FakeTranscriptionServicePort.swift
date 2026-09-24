//  FakeTranscriptionServicePort — C-012 v9 §«Фейк для тестов»: подставная реализация
//  доменного порта `TranscriptionServicePort` — та часть, что проверяет обработчика задачи
//  `transcribe` (§4/§4.1) на границе с очередью, не сам провод/движок (MEE-394).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)

import Foundation
import DomainCore

public final class FakeTranscriptionServicePort: TranscriptionServicePort, @unchecked Sendable {
    /// Заданная тестом ошибка — бросается из `transcribe`, если задана. Проверяется раньше
    /// `forcedResult`: этим методом тесты §4 задают именно вектор отказа.
    public var forcedError: TranscriptionServiceError?

    /// Заданный тестом результат успеха. По умолчанию — фикстура, годная по инвариантам C-003,
    /// чтобы вызов без явной настройки не падал `fatalError` по не относящейся к тесту причине.
    public var forcedResult: () throws -> Transcript = { TranscriptFixtures.oneOnOne }

    /// Прогресс, переданный `run` в вызовы `progress`, в порядке передачи.
    public var progressScript: [TranscriptionProgress] = []

    public init() {}

    public func transcribe(
        _ spec: TranscriptionJobSpec,
        progress: @Sendable @escaping (TranscriptionProgress) -> Void
    ) async throws -> Transcript {
        for step in progressScript { progress(step) }
        if let forcedError { throw forcedError }
        return try forcedResult()
    }

    public func embed(recordingId: UUID, startMs: Int, endMs: Int, profileId: String) async throws -> [Float] {
        []
    }

    public func ping() async throws -> String { "fake-transcription-service" }
}
