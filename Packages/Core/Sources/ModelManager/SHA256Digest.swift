//  SHA256Digest — потоковый SHA-256 (FIPS 180-4) для сверки файлов модели (C-014 инв. 4, §5, §6 п. 6).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  Свой, а не CryptoKit: CryptoKit — фреймворк Apple, на `Core (Linux)` его нет (инв. 20),
//  а внешняя зависимость (swift-crypto) — изменение границ пакета, не коммит (Package.swift).
//  Потоковый: файл читается порциями, модель в гигабайты в память не собирается (§6 п. 7).
//  Корректность держат тесты на векторах NIST (`SHA256DigestTests`).

import Foundation

struct SHA256Digest {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var buffer: [UInt8] = []
    private var totalBytes: UInt64 = 0
    private var words = [UInt32](repeating: 0, count: 64)

    init() {}

    mutating func update(_ data: Data) {
        totalBytes &+= UInt64(data.count)
        buffer.append(contentsOf: data)
        var offset = 0
        while buffer.count - offset >= 64 {
            compress(buffer, at: offset)
            offset += 64
        }
        if offset > 0 {
            buffer.removeFirst(offset)
        }
    }

    /// Итог в виде 64 шестнадцатеричных символов в нижнем регистре — форма `ModelFile.sha256`.
    mutating func finalizeHex() -> String {
        let bitLength = totalBytes &* 8
        var tail: [UInt8] = [0x80]
        let padding = (64 + 56 - (buffer.count + 1) % 64) % 64
        tail.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        buffer.append(contentsOf: tail)
        var offset = 0
        while offset < buffer.count {
            compress(buffer, at: offset)
            offset += 64
        }
        buffer.removeAll()
        return state.map { word in
            let text = String(word, radix: 16)
            return String(repeating: "0", count: 8 - text.count) + text
        }.joined()
    }

    static func hex(of data: Data) -> String {
        var digest = SHA256Digest()
        digest.update(data)
        return digest.finalizeHex()
    }

    /// Хеш файла, читаемого порциями по 1 МиБ.
    static func hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256Digest()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            digest.update(chunk)
        }
        return digest.finalizeHex()
    }

    private mutating func compress(_ bytes: [UInt8], at offset: Int) {
        for index in 0..<16 {
            let base = offset + index * 4
            words[index] = UInt32(bytes[base]) << 24 | UInt32(bytes[base + 1]) << 16
                | UInt32(bytes[base + 2]) << 8 | UInt32(bytes[base + 3])
        }
        for index in 16..<64 {
            let sigma0 = rotate(words[index - 15], 7) ^ rotate(words[index - 15], 18) ^ (words[index - 15] >> 3)
            let sigma1 = rotate(words[index - 2], 17) ^ rotate(words[index - 2], 19) ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ sigma0 &+ words[index - 7] &+ sigma1
        }
        var regA = state[0], regB = state[1], regC = state[2], regD = state[3]
        var regE = state[4], regF = state[5], regG = state[6], regH = state[7]
        for index in 0..<64 {
            let sum1 = rotate(regE, 6) ^ rotate(regE, 11) ^ rotate(regE, 25)
            let choice = (regE & regF) ^ (~regE & regG)
            let temp1 = regH &+ sum1 &+ choice &+ Self.roundConstants[index] &+ words[index]
            let sum0 = rotate(regA, 2) ^ rotate(regA, 13) ^ rotate(regA, 22)
            let majority = (regA & regB) ^ (regA & regC) ^ (regB & regC)
            regH = regG
            regG = regF
            regF = regE
            regE = regD &+ temp1
            regD = regC
            regC = regB
            regB = regA
            regA = temp1 &+ sum0 &+ majority
        }
        state[0] &+= regA
        state[1] &+= regB
        state[2] &+= regC
        state[3] &+= regD
        state[4] &+= regE
        state[5] &+= regF
        state[6] &+= regG
        state[7] &+= regH
    }

    private func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
