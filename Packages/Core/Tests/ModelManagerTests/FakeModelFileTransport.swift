//  FakeModelFileTransport — тестовая реализация `ModelFileTransport` (C-014 v7 §6, «Фейк для
//  тестов»: живёт в ModelManagerTests, шов берётся через `@testable import`).
//
//  Один шов на байты каталога и на файлы модели (план MEE-436 §1, ФСТ). Без сети: отдаёт
//  заранее заданные байты по адресу, по умолчанию честно поддерживает диапазон (`206` с
//  `firstByte`), а сценарий на адрес задаёт обрыв, `200` вместо `206`, рассинхрон диапазона,
//  код ответа, ожидание отмены. Каждый запрос записывается: адрес и `firstByte`.

import Foundation
import DomainCore
@testable import ModelManager

/// Шаг сценария на один запрос по адресу.
enum FakeStep: Sendable {
    /// Честный ответ: `206` с `firstByte` (или `200` при `firstByte == 0`), тело целиком.
    case serve
    /// Как `serve`, но после `bytes` байт тела связь обрывается.
    case dropAfter(bytes: Int)
    /// Сервер не поддержал диапазон: `200` и ресурс целиком.
    case ignoreRange
    /// Произвольный ответ: код, первый байт `Content-Range`, тело.
    case respond(status: Int, firstByte: Int64?, body: Data)
    /// Сетевой отказ до первого байта.
    case fail
    /// Ждёт отмены задачи, не отдав ни байта.
    case waitForCancellation
}

struct FakeRequest: Equatable, Sendable {
    let url: URL
    let firstByte: Int64

    /// Заголовок, который нёс бы запрос (К18, К22): построен той же чистой функцией, что боевой.
    var rangeHeaderLine: String? { ModelFileRequest.rangeHeaderLine(firstByte: firstByte) }
}

struct FakeNetworkError: Error {}

private struct FakePlan {
    let step: FakeStep
    let content: Data
    let hook: (@Sendable (URL, Int) async throws -> Void)?
    let headHook: (@Sendable (URL, HTTPRangeResponse, Bool) async -> Void)?
    let index: Int
}

final class FakeModelFileTransport: ModelFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [URL: Data] = [:]
    private var scripts: [URL: [FakeStep]] = [:]
    private var log: [FakeRequest] = []
    private var chunkHook: (@Sendable (URL, Int) async throws -> Void)?
    private var headHook: (@Sendable (URL, HTTPRangeResponse, Bool) async -> Void)?
    private var receiveCounts: [Int] = []

    /// Размер порции тела: несколько порций на файл — чтобы наблюдать `.part` между ними.
    var chunkSize = 16

    func setContent(_ data: Data, at url: URL) {
        locked { contents[url] = data }
    }

    func script(_ url: URL, _ steps: [FakeStep]) {
        locked { scripts[url, default: []].append(contentsOf: steps) }
    }

    /// Вызывается ПОСЛЕ каждой отданной порции: (адрес, номер порции с нуля).
    func onChunk(_ hook: (@Sendable (URL, Int) async throws -> Void)?) {
        locked { chunkHook = hook }
    }

    /// Вызывается сразу ПОСЛЕ `head` менеджера: (адрес, ответ, бросил ли `head`) — К19, К21.
    func onHead(_ hook: (@Sendable (URL, HTTPRangeResponse, Bool) async -> Void)?) {
        locked { headHook = hook }
    }

    var requests: [FakeRequest] { locked { log } }

    /// Сколько раз вызван `receive` в каждом запросе, в порядке запросов.
    var receives: [Int] { locked { receiveCounts } }

    func requests(for url: URL) -> [FakeRequest] {
        requests.filter { $0.url == url }
    }

    func fetch(url: URL,
               firstByte: Int64,
               head: @Sendable (HTTPRangeResponse) async throws -> Void,
               receive: @Sendable (Data) async throws -> Void) async throws {
        let plan = locked { () -> FakePlan in
            log.append(FakeRequest(url: url, firstByte: firstByte))
            receiveCounts.append(0)
            var queue = scripts[url] ?? []
            let next = queue.isEmpty ? FakeStep.serve : queue.removeFirst()
            scripts[url] = queue
            return FakePlan(step: next, content: contents[url] ?? Data(), hook: chunkHook, headHook: headHook,
                            index: log.count - 1)
        }
        let content = plan.content
        let total = Int64(content.count)
        // §6 (v7): `head` ровно раз и до первого `receive`; бросок из `head` — тело не отдаётся.
        func respond(_ status: Int, _ first: Int64?, _ body: Data) async throws {
            let response = HTTPRangeResponse(statusCode: status, firstByte: first, totalBytes: total)
            do {
                try await head(response)
            } catch {
                await plan.headHook?(url, response, true)
                throw error
            }
            await plan.headHook?(url, response, false)
            let index = plan.index
            try await deliver(body, url: url, hook: plan.hook) { chunk in
                self.locked { self.receiveCounts[index] += 1 }
                try await receive(chunk)
            }
        }
        switch plan.step {
        case .serve:
            try await respond(firstByte > 0 ? 206 : 200, firstByte > 0 ? firstByte : nil,
                              Data(content.dropFirst(Int(firstByte))))
        case .dropAfter(let bytes):
            try await respond(firstByte > 0 ? 206 : 200, firstByte > 0 ? firstByte : nil,
                              Data(content.dropFirst(Int(firstByte)).prefix(bytes)))
            throw FakeNetworkError()
        case .ignoreRange:
            try await respond(200, nil, content)
        case .respond(let status, let first, let body):
            try await respond(status, first, body)
        case .fail:
            throw FakeNetworkError()
        case .waitForCancellation:
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            throw CancellationError()
        }
    }

    private func deliver(_ body: Data, url: URL,
                         hook: (@Sendable (URL, Int) async throws -> Void)?,
                         receive: @Sendable (Data) async throws -> Void) async throws {
        var offset = 0
        var index = 0
        let size = max(1, chunkSize)
        while offset < body.count {
            try Task.checkCancellation()
            let end = min(body.count, offset + size)
            try await receive(body.subdata(in: (body.startIndex + offset)..<(body.startIndex + end)))
            try await hook?(url, index)
            offset = end
            index += 1
        }
    }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Тестовая машина: чип, память, свободное место задаются тестом (К24, К25).
final class FakeMachine: MachineEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var chipValue: MinChip? = .m4
    private var memory: UInt64 = 64 << 30
    private var disk: Int64? = 1 << 40

    func set(chip: MinChip?) {
        locked { chipValue = chip }
    }

    func set(memoryGB: Int) {
        locked { memory = UInt64(memoryGB) << 30 }
    }

    func set(diskBytes: Int64?) {
        locked { disk = diskBytes }
    }

    func chip() -> MinChip? {
        locked { chipValue }
    }

    func physicalMemoryBytes() -> UInt64 {
        locked { memory }
    }

    func availableDiskBytes(at url: URL) -> Int64? {
        locked { disk }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
