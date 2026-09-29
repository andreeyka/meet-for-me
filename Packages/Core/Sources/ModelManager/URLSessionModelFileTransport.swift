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
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
