//  EmbeddingCodec — `speaker_profiles.embedding`, C-010 (MEE-18) v7 §3.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  «Float32 little-endian подряд, без заголовка» (§3) — кодируется через
//  битовый паттерн, а не через сырую память: архитектура раннера (macOS
//  ARM64) сама little-endian, но код не полагается на это молча.

import Foundation

enum EmbeddingCodec {

    static func encode(_ floats: [Float]) -> Data {
        var data = Data(capacity: floats.count * 4)
        for value in floats {
            let bits = value.bitPattern.littleEndian
            data.append(contentsOf: [
                UInt8(bits & 0xFF),
                UInt8((bits >> 8) & 0xFF),
                UInt8((bits >> 16) & 0xFF),
                UInt8((bits >> 24) & 0xFF)
            ])
        }
        return data
    }

    /// Инвариант 11: длина ровно `embedding_dim * 4`. Возвращает `nil`, если
    /// байтов не кратно четырём или их число не совпадает с ожидаемым.
    static func decode(_ data: Data, expectedDimension: Int) -> [Float]? {
        guard data.count == expectedDimension * 4 else { return nil }
        var result: [Float] = []
        result.reserveCapacity(expectedDimension)
        var index = data.startIndex
        while index < data.endIndex {
            let bytes = data[index..<data.index(index, offsetBy: 4)]
            var bits: UInt32 = 0
            for (position, byte) in bytes.enumerated() {
                bits |= UInt32(byte) << (8 * position)
            }
            result.append(Float(bitPattern: UInt32(littleEndian: bits)))
            index = data.index(index, offsetBy: 4)
        }
        return result
    }
}
