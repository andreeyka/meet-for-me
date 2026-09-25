//  TemporaryTranscriptionServiceStub — временная заглушка `TranscriptionServicePort` до
//  готовности `EngineXPCClient` (MEE-431, DEV-2). MEE-433, решение РП п.5: в `EngineKit/Fakes`
//  нет готового конформера этого порта — `LoopbackEngineTransport` разбирает
//  `EngineRequest`/`EngineReply` (другой уровень, провод XPC), не сигнатуру
//  `transcribe(_:progress:)` напрямую. Честно отвечает отказом «движок недоступен», не выдаёт
//  фальшивый транскрипт.
//
//  ЗАМЕНИТЬ НА EngineXPCClient С MEE-431.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: composition root (временная заглушка)

import DomainCore
import Foundation

struct TemporaryTranscriptionServiceStub: TranscriptionServicePort {

    private struct EngineUnavailableError: LocalizedError {
        var errorDescription: String? {
            "движок недоступен: EngineXPCClient ещё не реализован (MEE-431)"
        }
    }

    func transcribe(
        _ spec: TranscriptionJobSpec,
        progress: @Sendable @escaping (TranscriptionProgress) -> Void
    ) async throws -> Transcript {
        throw EngineUnavailableError()
    }

    func embed(recordingId: UUID, startMs: Int, endMs: Int, profileId: String) async throws -> [Float] {
        throw EngineUnavailableError()
    }

    func ping() async throws -> String {
        throw EngineUnavailableError()
    }
}
