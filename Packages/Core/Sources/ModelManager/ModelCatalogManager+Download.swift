//  ModelCatalogManager — загрузка с докачкой по HTTP-диапазону (C-014 v7 §6; инв. 4, 5, 16,
//  17, 26, 27, 29, 36).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  Каждый файл — отдельный `GET`; при `.part` длины `L > 0` — `Range: bytes=<L>-` (§6 п. 1–2).
//  Тело пишется в `.part` по мере поступления (п. 7). По завершении файла — длина, затем
//  `sha256`; совпало — переименование, нет — удаление всех файлов модели и
//  `error(checksumMismatch)` (п. 6, инв. 4). `.manifest.json` — только после сверки всех файлов.
//
//  Шов отдаёт `HTTPRangeResponse` в `head` ДО тела (v7, IR-141 п. 5), и решение по пп. 3–5
//  принимается до первого байта: `206` с первым байтом `L` — тело дописывается в конец
//  `.part`; `200` — `.part` усекается до нуля и пишется с начала (п. 4), поэтому его длина
//  не превосходит `files[].sizeBytes` ни на одном ответе; `206` с иным первым байтом либо
//  `416` — `.part` удаляется, бросок из `head`, файл качается с нуля ОДИН раз (п. 5).
//
//  Обрыв связи и отмена оставляют `.part` для докачки: `paused(bytesOnDisk:)`, либо
//  `available`, если на диске нет ни байта (инв. 26). Отказ сервера (код ответа, повторный
//  рассинхрон диапазона) — `error(downloadFailed)` с сохранённым `.part` (инв. 27).

import Foundation
import DomainCore

extension ModelCatalogManager {

    /// Параллельный вызов для той же модели не начинает вторую загрузку и не возвращается
    /// раньше первой: он ждёт идущую и получает её исход — успех только после `downloaded`,
    /// иначе ту же ошибку (инв. 4; возврат РП `e64cbd81`, п. 1).
    public func download(id: String, version: String) async throws {
        let key = ModelKey(id: id, version: version)
        if let running = runningDownloads[key] {
            return try await running.value
        }
        let task = Task { () throws in
            do {
                try await self.performDownload(key)
            } catch {
                self.finishRun(key)
                throw error
            }
            self.finishRun(key)
        }
        runningDownloads[key] = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func finishRun(_ key: ModelKey) {
        runningDownloads[key] = nil
    }

    private func performDownload(_ key: ModelKey) async throws {
        guard let descriptor = catalogDescriptor(key) else {
            throw ModelCatalogError.unknownModel(id: key.id, version: key.version)
        }
        switch currentState(key) {
        case .downloaded, .loaded:
            return
        default:
            break
        }
        let directory = directory(for: descriptor)
        try checkThresholds(descriptor, directory)   // инв. 16, 17: до первого обращения к сети
        let session = DownloadSession()
        sessions[key] = session
        failures[key] = nil
        verified[key] = nil
        try? ModelDisk.remove(ModelDisk.manifestURL(in: directory))
        publish(key, currentState(key))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in descriptor.files {
                try await fetchFile(file, key: key, directory: directory, session: session)
            }
            try writeManifest(descriptor, in: directory)
            sessions[key] = nil
            verified[key] = .passed
            publish(key, currentState(key))
        } catch {
            throw finishFailed(key, descriptor: descriptor, directory: directory, session: session, error: error)
        }
    }

    public func cancelDownload(id: String, version: String) async {
        guard let session = sessions[ModelKey(id: id, version: version)] else { return }
        session.cancelRequested = true
        session.stop()
    }

    // MARK: - Пороги

    private func checkThresholds(_ descriptor: ModelDescriptor, _ directory: URL) throws {
        if let chip = environment.chip(), chip < descriptor.minChip {
            throw ModelCatalogError.unsupportedChip(required: descriptor.minChip)
        }
        let memoryGB = Int(environment.physicalMemoryBytes() / (1 << 30))
        if descriptor.minRAMGB > memoryGB {
            throw ModelCatalogError.insufficientRAM(requiredGB: descriptor.minRAMGB)
        }
        let required = max(0, descriptor.sizeBytes - ModelDisk.occupiedBytes(in: directory))
        if let available = environment.availableDiskBytes(at: directory), available < required {
            throw ModelCatalogError.insufficientDiskSpace(requiredBytes: required, availableBytes: available)
        }
    }

    // MARK: - Один файл

    private func fetchFile(_ file: ModelFile, key: ModelKey, directory: URL, session: DownloadSession) async throws {
        let finalURL = ModelDisk.fileURL(in: directory, name: file.name)
        let partURL = ModelDisk.partURL(in: directory, name: file.name)
        if ModelDisk.exists(finalURL) {
            // Готовый файл на диске: годен — докачивать нечего. Негоден (испорчен после сверки,
            // ручная установка) — удаляется и качается с нуля в этой же попытке (§6 п. 6,
            // `error → downloading` инв. 6; возврат РП `e64cbd81`, п. 2).
            if (try? checkFile(finalURL, file)) != nil {
                return
            }
            try ModelDisk.remove(finalURL)
        }
        var restarted = false
        while true {
            let start = ModelDisk.size(of: partURL) ?? 0
            if start >= file.sizeBytes, start > 0 {
                break                              // `.part` уже полон — сразу к сверке
            }
            session.partURL = partURL
            do {
                try await runFetch(file.url, firstByte: start, partURL: partURL, key: key, session: session)
                session.closeHandle()
                try checkStopped(session)
                break
            } catch DownloadFailure.rangeMismatch(let status) {
                session.closeHandle()
                try checkStopped(session)
                guard !restarted else {
                    throw DownloadFailure.http("диапазон не сошёлся повторно (HTTP \(status))")
                }
                restarted = true
            }
        }
        try checkFile(partURL, file)
        try FileManager.default.moveItem(at: partURL, to: finalURL)
    }

    /// Решение по статусу (§6 пп. 3–5), до первого байта тела. Бросок прерывает запрос.
    private func acceptHead(_ response: HTTPRangeResponse, start: Int64, partURL: URL,
                            key: ModelKey, session: DownloadSession) throws {
        guard sessions[key] === session, !session.isStopped else {
            throw CancellationError()
        }
        switch response.statusCode {
        case 206 where (response.firstByte ?? start) == start:
            return                                 // п. 3: дописывать в конец `.part`
        case 200:
            try ModelDisk.truncate(partURL, to: 0) // п. 4: ресурс целиком — `.part` с нуля
        case 206, 416:
            try ModelDisk.remove(partURL)          // п. 5: с нуля, один повтор
            throw DownloadFailure.rangeMismatch(status: response.statusCode)
        default:
            throw DownloadFailure.http("HTTP \(response.statusCode)")
        }
    }

    private func checkFile(_ url: URL, _ file: ModelFile) throws {
        let actual = (try? SHA256Digest.hex(ofFileAt: url)) ?? ""
        guard ModelDisk.size(of: url) == file.sizeBytes, actual == file.sha256 else {
            throw DownloadFailure.checksum(fileName: file.name, expected: file.sha256, actual: actual)
        }
    }

    private func checkStopped(_ session: DownloadSession) throws {
        if session.isStopped {
            throw CancellationError()
        }
    }

    /// Запрос идёт отдельной задачей: `cancelDownload` обязана прервать и ожидание первого байта.
    private func runFetch(_ url: URL, firstByte: Int64, partURL: URL, key: ModelKey,
                          session: DownloadSession) async throws {
        try checkStopped(session)
        let transport = self.transport
        let task = Task { () throws in
            try await transport.fetch(url: url, firstByte: firstByte, head: { [weak self] response in
                guard let self else { throw CancellationError() }
                try await self.acceptHead(response, start: firstByte, partURL: partURL, key: key, session: session)
            }, receive: { [weak self] chunk in
                guard let self else { throw CancellationError() }
                try await self.append(chunk, key: key, session: session)
            })
        }
        session.fetchTask = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Порция тела — в конец `.part` сразу (§6 п. 7). `.part` создаётся первым байтом (инв. 26).
    private func append(_ chunk: Data, key: ModelKey, session: DownloadSession) throws {
        guard sessions[key] === session, !session.isStopped, let partURL = session.partURL else {
            throw CancellationError()
        }
        if session.handle == nil {
            if !ModelDisk.exists(partURL) {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partURL)
            try handle.seekToEnd()
            session.handle = handle
        }
        try session.handle?.write(contentsOf: chunk)
        let fraction = fraction(key)
        let percent = Int(fraction * 100)
        if percent != session.publishedPercent {
            session.publishedPercent = percent
            publish(key, .downloading(fraction: fraction))
        }
    }

    // MARK: - Исход неудачной загрузки

    private func finishFailed(_ key: ModelKey, descriptor: ModelDescriptor, directory: URL,
                              session: DownloadSession, error: Error) -> ModelCatalogError {
        session.closeHandle()
        if session.deleted {
            return .cancelled                       // `delete` уже убрал каталог и опубликовал `available`
        }
        sessions[key] = nil
        let result: ModelCatalogError
        switch error {
        case DownloadFailure.checksum(let name, let expected, let actual):
            try? ModelDisk.remove(directory)        // инв. 4: и готовые файлы, и `.part`
            result = .checksumMismatch(fileName: name, expected: expected, actual: actual)
            failures[key] = result
        case DownloadFailure.http(let message):
            result = .downloadFailed(message: message)
            failures[key] = result
        default:
            result = session.cancelRequested || error is CancellationError
                ? .cancelled
                : .downloadFailed(message: String(describing: error))
            dropIfEmpty(directory)
        }
        publish(key, currentState(key))
        return result
    }

    /// Каталог без единого байта удаляется: `available` значит «на диске нет ни байта» (инв. 26).
    private func dropIfEmpty(_ directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(ModelDisk.partSuffix) {
            let url = directory.appendingPathComponent(name)
            if ModelDisk.size(of: url) == 0 {
                try? ModelDisk.remove(url)
            }
        }
        if ModelDisk.occupiedBytes(in: directory) == 0 {
            try? ModelDisk.remove(directory)
        }
    }
}
