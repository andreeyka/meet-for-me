//  ModelFileTransport и HTTPRangeResponse — шов загрузки по HTTP-диапазону (C-014 v7 §6).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  Оба типа `internal` (C-014 §0, §6, инв. 32): границу модуля не пересекают. Тестовая
//  реализация живёт в `ModelManagerTests` и берёт шов через `@testable import`.
//  Один шов на байты каталога (`refreshCatalog`) и на файлы модели (`download`).
//
//  v7 (IR-141, п. 5): статус приходит в `head` ДО тела, а не результатом `fetch` после него —
//  решение по §6 пп. 3–5 (дописать, усечь до нуля, начать заново) принимается до первого байта.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Объявлен в ModelManager и `internal`: границу модуля не пересекает (инвариант 32).
struct HTTPRangeResponse: Equatable, Sendable {
    let statusCode: Int        // 200 | 206 | иной
    let firstByte: Int64?      // первый байт из Content-Range; nil, если заголовка нет
    let totalBytes: Int64?     // полный размер ресурса, если сервер его назвал
}

/// Объявлен в ModelManager и `internal`: границу модуля не пересекает (инвариант 32).
protocol ModelFileTransport: Sendable {
    /// GET url. При firstByte > 0 запрос обязан нести заголовок "Range: bytes=<firstByte>-".
    /// head вызывается ровно один раз и ДО первого receive — с кодом ответа и Content-Range;
    /// бросок из head прерывает запрос, не читая тела. Байты тела отдаются в receive по мере поступления.
    func fetch(url: URL,
               firstByte: Int64,
               head: @Sendable (HTTPRangeResponse) async throws -> Void,
               receive: @Sendable (Data) async throws -> Void) async throws
}

/// Построение запроса — чистая функция (§6, тест «Форма заголовка»).
enum ModelFileRequest {
    static let rangeHeaderName = "Range"

    /// Значение заголовка `Range` для докачки с байта `firstByte`; `nil` — заголовок не нужен.
    static func rangeHeaderValue(firstByte: Int64) -> String? {
        firstByte > 0 ? "bytes=\(firstByte)-" : nil
    }

    /// Заголовок целиком, как он уходит в запрос: `Range: bytes=1024-`.
    static func rangeHeaderLine(firstByte: Int64) -> String? {
        rangeHeaderValue(firstByte: firstByte).map { "\(rangeHeaderName): \($0)" }
    }

    static func request(url: URL, firstByte: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let value = rangeHeaderValue(firstByte: firstByte) {
            request.setValue(value, forHTTPHeaderField: rangeHeaderName)
        }
        return request
    }

    /// Разбор `Content-Range: bytes <first>-<last>/<total|*>` → (первый байт, полный размер).
    static func parseContentRange(_ value: String?) -> (firstByte: Int64?, totalBytes: Int64?) {
        guard let value = value?.trimmingCharacters(in: .whitespaces), value.hasPrefix("bytes ") else {
            return (nil, nil)
        }
        let spec = value.dropFirst("bytes ".count)
        let halves = spec.split(separator: "/", maxSplits: 1).map(String.init)
        let first = halves.first?.split(separator: "-").first.flatMap { Int64($0) }
        let total = halves.count == 2 ? Int64(halves[1]) : nil
        return (first, total)
    }
}
