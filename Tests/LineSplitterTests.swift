import XCTest

@testable import AIPulse

final class LineSplitterTests: XCTestCase {
    func testSplitsLinesAcrossArbitraryChunkBoundaries() {
        let content = Data("first\nsecond\n".utf8)
        var splitter = LineSplitter()
        var lines = [String]()

        let bytes = [UInt8](content)
        for offset in stride(from: 0, to: bytes.count, by: 3) {
            let end = min(offset + 3, bytes.count)
            splitter.append(Data(bytes[offset..<end])) { lines.append($0) }
        }

        XCTAssertEqual(lines, ["first", "second"])
        XCTAssertTrue(splitter.pendingBytes.isEmpty)
    }

    func testPreservesPartialLineForNextChunk() {
        var splitter = LineSplitter()
        var lines = [String]()

        splitter.append(Data("multi".utf8)) { lines.append($0) }
        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(splitter.pendingBytes, Data("multi".utf8))

        splitter.append(Data("line\n".utf8)) { lines.append($0) }
        XCTAssertEqual(lines, ["multiline"])
        XCTAssertTrue(splitter.pendingBytes.isEmpty)
    }

    func testHandlesMultibyteCharacterSplitAcrossChunks() {
        let text = "中文\n"
        let bytes = Data(text.utf8)
        var splitter = LineSplitter()
        var lines = [String]()

        splitter.append(bytes.prefix(4)) { lines.append($0) }
        splitter.append(bytes.suffix(bytes.count - 4)) { lines.append($0) }

        XCTAssertEqual(lines, [text.trimmingCharacters(in: .newlines)])
    }

    func testDiscardsOversizedLineWithoutRetainingIt() {
        var splitter = LineSplitter(maxLineBytes: 8)
        var lines = [String]()

        splitter.append(Data("1234567890\nok\n".utf8)) { lines.append($0) }

        XCTAssertEqual(lines, ["ok"])
        XCTAssertTrue(splitter.pendingBytes.isEmpty)
    }
}
