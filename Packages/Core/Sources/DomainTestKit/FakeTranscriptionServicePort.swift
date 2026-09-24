//  FakeTranscriptionServicePort — C-012 v10 §«Фейк для тестов»: подставная реализация
//  доменного порта `TranscriptionServicePort` — та часть, что проверяет обработчика задачи
//  `transcribe` (§4/§4.1) на границе с очередью, не сам провод/движок (MEE-394).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Состав — контракт дословно: «возвращает заданный `Transcript`, проигрывает заданную
//  последовательность `TranscriptionProgress`, бросает любую `TranscriptionServiceError` —
//  включая оба новых случая, — считает вызовы» (§«Фейк для тестов»). Возврат РП на #118:
//  счётчик и последний `spec` не были заведены изначально.

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

    /// К44/К45 (развилка `cancelled` по `Task.isCancelled`): вместо немедленного `throw`
    /// дожидается настоящей отмены объемлющего `Task`. Возврат РП на #118 — без точки
    /// ожидания `throw` мог случиться раньше, чем `task.cancel()` успевал долететь, и
    /// `Task.isCancelled` читался бы `false` даже там, где тест отменяет задачу.
    public var waitForCancellationBeforeThrowing = false

    private let lock = NSLock()
    private var callCount = 0
    private var lastSpec: TranscriptionJobSpec?

    public init() {}

    /// «Считает вызовы» контракта дословно.
    public var transcribeCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return callCount
    }

    /// `spec` последнего вызова `transcribe` — `nil`, если вызовов ещё не было.
    public var lastTranscribedSpec: TranscriptionJobSpec? {
        lock.lock(); defer { lock.unlock() }
        return lastSpec
    }

    public func transcribe(
        _ spec: TranscriptionJobSpec,
        progress: @Sendable @escaping (TranscriptionProgress) -> Void
    ) async throws -> Transcript {
        lock.lock()
        callCount += 1
        lastSpec = spec
        lock.unlock()
        for step in progressScript { progress(step) }
        if let forcedError {
            if waitForCancellationBeforeThrowing {
                await waitUntilCancelled()
            }
            throw forcedError
        }
        return try forcedResult()
    }

    public func embed(recordingId: UUID, startMs: Int, endMs: Int, profileId: String) async throws -> [Float] {
        []
    }

    public func ping() async throws -> String { "fake-transcription-service" }

    /// Возврат РП на #120: `Task.sleep(nanoseconds: .max)` на Linux (Swift 5.10, docker
    /// `swift:5.10`) возвращался немедленно, без отмены, — судя по всему, переполнение при
    /// расчёте срока сна. Точки ожидания на Linux не было вовсе, и гонка К44/К45 оставалась
    /// (CI был зелёным лишь потому, что `cancel()` почти всегда успевал раньше). Ограниченный
    /// срок — 5 секунд, не весь `UInt64`, — даёт настоящую точку ожидания на обеих платформах
    /// И страховку: без отмены тест упадёт понятным `.permanentFailure`, а не повиснет.
    private func waitUntilCancelled() async {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
}
