//  URLSessionModelFileTransport — боевая реализация `ModelFileTransport` поверх `URLSession`
//  из Foundation (C-014 v6 §6, инв. 5, 20).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  Три обязательные вещи §6: заголовок `Range: bytes=<L>-` (`ModelFileRequest`); байты
//  отдаются в `receive` по мере поступления (делегат `URLSessionDataDelegate`, а не
//  `data(for:)`, собирающий тело в памяти); механизма продолжения URLSession, запрещённого
//  §6 дословно, здесь нет. `URLSession.bytes(for:)` не годится: в swift-corelibs его нет,
//  а исходник обязан быть одним на `Core (Linux)` и `macos-14`.
//
//  `FoundationNetworking` — только под `#if canImport` (К44): на Darwin такого модуля нет.
//
//  ОБРАТНОЕ ДАВЛЕНИЕ (C-014 §6 п. 7, MEE-458 п.4): «модель в два гигабайта не собирается в
//  памяти ни на одном этапе». Делегат кладёт куски в поток быстрее, чем `receive` пишет их на
//  диск, — без предела буфер потока растёт до размера файла. `BackpressureGate` считает байты,
//  отданные в поток и ещё не записанные: на `highWaterBytes` задача приостанавливается
//  (`suspend()`), на `lowWaterBytes` — возобновляется (`resume()`). Сверх предела в буфере
//  может лечь только то, что URLSession уже вёз к делегату в момент остановки.
//
//  Проверяется в CI только сборкой обеих работ: живой CDN в тестах не трогается (§6,
//  «Чего эти тесты не проверяют»). Поведение шва проверяется тестовым транспортом.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct URLSessionModelFileTransport: ModelFileTransport {

    func fetch(url: URL,
               firstByte: Int64,
               receive: @Sendable (Data) async throws -> Void) async throws -> HTTPRangeResponse {
        let delegate = StreamingDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: ModelFileRequest.request(url: url, firstByte: firstByte))
        return try await withTaskCancellationHandler {
            task.resume()
            // Выход по отказу `receive` (или по брошенному потоку) не оставляет задачу качать
            // дальше — и тем более остановленной `suspend()` навсегда: после завершения
            // `cancel()` ничего не делает.
            defer { task.cancel() }
            var response: HTTPRangeResponse?
            for try await event in delegate.events {
                switch event {
                case .response(let head):
                    response = head
                case .body(let data):
                    // Тело ответа-отказа (404, 416, 5xx) — не байты ресурса: в `.part` оно не идёт.
                    if let status = response?.statusCode, status == 200 || status == 206 {
                        try await receive(data)
                    }
                    delegate.gate.consumed(data.count) { task.resume() }
                }
            }
            guard let response else {
                throw URLError(.badServerResponse)
            }
            return response
        } onCancel: {
            task.cancel()
        }
    }
}

/// Делегат, превращающий обратные вызовы URLSession в поток событий.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    enum Event {
        case response(HTTPRangeResponse)
        case body(Data)
    }

    let events: AsyncThrowingStream<Event, Error>
    let gate = BackpressureGate()
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation

    override init() {
        var captured: AsyncThrowingStream<Event, Error>.Continuation?
        events = AsyncThrowingStream { captured = $0 }
        guard let captured else {
            preconditionFailure("AsyncThrowingStream отдаёт continuation синхронно")
        }
        continuation = captured
        super.init()
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let range = ModelFileRequest.parseContentRange(http?.value(forHTTPHeaderField: "Content-Range"))
        let length = response.expectedContentLength
        let total = range.totalBytes ?? (status == 200 && length >= 0 ? length : nil)
        continuation.yield(.response(HTTPRangeResponse(
            statusCode: status, firstByte: range.firstByte, totalBytes: total)))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.body(data))
        gate.enqueued(data.count) { dataTask.suspend() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

/// Счёт байт, отданных в поток и ещё не записанных, и решение «остановить/возобновить».
/// `pause`/`resume` исполняются ПОД ЗАМКОМ: иначе `resume()` потребителя мог бы обогнать
/// `suspend()` делегата, решённый раньше, и задача осталась бы остановленной при пустом буфере.
final class BackpressureGate: @unchecked Sendable {
    static let defaultHighWaterBytes = 8 * 1024 * 1024
    static let defaultLowWaterBytes = 2 * 1024 * 1024

    let highWaterBytes: Int
    let lowWaterBytes: Int
    private let lock = NSLock()
    private var buffered = 0
    private var paused = false

    init(highWaterBytes: Int = defaultHighWaterBytes, lowWaterBytes: Int = defaultLowWaterBytes) {
        precondition(lowWaterBytes < highWaterBytes, "нижний порог ниже верхнего")
        self.highWaterBytes = highWaterBytes
        self.lowWaterBytes = lowWaterBytes
    }

    var bufferedBytes: Int { locked { buffered } }
    var isPaused: Bool { locked { paused } }

    /// Кусок отдан в поток. `pause` — ровно один раз на переход через верхний порог.
    func enqueued(_ count: Int, pause: () -> Void) {
        locked {
            buffered += count
            if !paused, buffered >= highWaterBytes {
                paused = true
                pause()
            }
        }
    }

    /// Кусок записан (или отброшен). `resume` — ровно один раз на спуск до нижнего порога.
    func consumed(_ count: Int, resume: () -> Void) {
        locked {
            buffered -= count
            if paused, buffered <= lowWaterBytes {
                paused = false
                resume()
            }
        }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
