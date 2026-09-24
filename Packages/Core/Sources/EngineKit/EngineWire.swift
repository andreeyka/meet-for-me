//  EngineWire — C-012 v10 §2: единственный санкционированный способ кодировать байты,
//  идущие через границу транспорта (инвариант 14 — «всё, что видит транспорт, прошло через
//  него»). Формат — двоичный property list, не JSON: `Transcript.Speaker.embedding`
//  (`[Float]`) в JSON занимает на порядок больше места (C-012 §2, обоснование выбора).
//  `protocolVersion` — целое число, сравнивается на точное равенство, передаётся один раз
//  через `.pong`; это НЕ то же понятие, что строка `"MAJOR.MINOR"` C-006 §1.1 `schemaVersion`.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)
//
//  §2.1: `normalizingDates(_:)` округляет каждый `Date` ответа до ближайшей миллисекунды —
//  последний шаг сервиса перед `encode`, и только для исходящего `EngineReply`; `EngineRequest`
//  (входящее) не нормализуется. Единственный `Date` на графе типов этого модуля —
//  `Transcript.createdAt` (`Transcript.Segment`/`Word`/`Speaker` дат не несут).

import DomainCore
import Foundation

public enum EngineWire {
    public static let protocolVersion: Int = 1
    public static let maxMessageBytes: Int = 32 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }

    public static func normalizingDates(_ reply: EngineReply) throws -> EngineReply {
        guard case .transcript(let jobId, let transcript) = reply else { return reply }
        let rounded = try Transcript(
            schemaVersion: transcript.schemaVersion,
            recordingId: transcript.recordingId,
            language: transcript.language,
            engine: transcript.engine,
            modelVersion: transcript.modelVersion,
            createdAt: roundedToMillisecond(transcript.createdAt),
            segments: transcript.segments,
            speakers: transcript.speakers
        )
        return .transcript(jobId, rounded)
    }

    private static func roundedToMillisecond(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
