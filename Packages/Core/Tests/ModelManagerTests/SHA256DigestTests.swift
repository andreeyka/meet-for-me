//  Собственный SHA-256 модуля (CryptoKit на Linux нет) — векторы FIPS 180-4 / NIST CSVP.
//  От него зависит сверка файлов модели (инв. 4, §5), поэтому он проверяется отдельно, а не
//  только через совпадение с самим собой в тестах загрузки.

import XCTest
@testable import ModelManager

final class SHA256DigestTests: XCTestCase {

    func testKnownVectors() {
        XCTAssertEqual(SHA256Digest.hex(of: Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        let bits896 = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
            + "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        XCTAssertEqual(SHA256Digest.hex(of: Data(bits896.utf8)),
                       "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1", "896-битный вектор")
        XCTAssertEqual(SHA256Digest.hex(of: Data(repeating: 0x61, count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testStreamingEqualsOneShotAcrossBlockBoundaries() throws {
        let data = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        for split in [1, 55, 56, 63, 64, 65, 128, 999] {
            var digest = SHA256Digest()
            digest.update(data.prefix(split))
            digest.update(data.dropFirst(split))
            XCTAssertEqual(digest.finalizeHex(), SHA256Digest.hex(of: data), "разрез на \(split)")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        XCTAssertEqual(try SHA256Digest.hex(ofFileAt: url), SHA256Digest.hex(of: data))
    }

    func testChipParsingFromBrandString() {
        XCTAssertEqual(SystemMachineEnvironment.chip(fromBrand: "Apple M1"), .m1)
        XCTAssertEqual(SystemMachineEnvironment.chip(fromBrand: "Apple M2 Pro"), .m2)
        XCTAssertEqual(SystemMachineEnvironment.chip(fromBrand: "Apple M5 Max"), .m4, "новее m4 — как m4")
        XCTAssertNil(SystemMachineEnvironment.chip(fromBrand: "Intel(R) Core(TM) i7"))
    }

    func testContentRangeParsing() {
        let parsed = ModelFileRequest.parseContentRange("bytes 100-199/200")
        XCTAssertEqual(parsed.firstByte, 100)
        XCTAssertEqual(parsed.totalBytes, 200)
        XCTAssertNil(ModelFileRequest.parseContentRange(nil).firstByte)
        XCTAssertNil(ModelFileRequest.parseContentRange("bytes */200").firstByte)
    }
}
