import XCTest

@testable import AIPulse

final class ZstdStreamDecoderTests: XCTestCase {
    private let zstdFrame = Data([
        0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x58, 0x59, 0x00,
        0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x7a,
        0x73, 0x74, 0x64, 0x0a,
    ])

    func testDecodesInputFedInSmallChunks() throws {
        // `zstd -3 --no-check` frame for "hello zstd\n".
        let compressed = zstdFrame
        var decoded = Data()
        let decoder = try ZstdStreamDecoder()

        for offset in stride(from: 0, to: compressed.count, by: 3) {
            let end = min(offset + 3, compressed.count)
            try decoder.decompress(compressed[offset..<end]) { decoded.append($0) }
        }
        try decoder.finish { decoded.append($0) }

        XCTAssertEqual(decoded, Data("hello zstd\n".utf8))
    }

    func testDecodesConcatenatedFramesAcrossChunkBoundaries() throws {
        let compressed = zstdFrame + zstdFrame
        var decoded = Data()
        let decoder = try ZstdStreamDecoder()

        for offset in stride(from: 0, to: compressed.count, by: 7) {
            let end = min(offset + 7, compressed.count)
            try decoder.decompress(compressed[offset..<end]) { decoded.append($0) }
        }
        try decoder.finish { decoded.append($0) }

        XCTAssertEqual(decoded, Data("hello zstd\nhello zstd\n".utf8))
    }

    func testRejectsTruncatedFrame() throws {
        let compressed = Data([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x58, 0x59])
        let decoder = try ZstdStreamDecoder()

        try decoder.decompress(compressed) { _ in }
        XCTAssertThrowsError(try decoder.finish { _ in })
    }

}
