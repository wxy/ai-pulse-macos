import XCTest
@testable import AIPulse

final class StableHashTests: XCTestCase {
    func testDeterministicAcrossCalls() {
        let input = "> Tokens: 12k sent, 47 received. Cost: $0.0034 message"
        XCTAssertEqual(stableHash(input), stableHash(input))
    }

    func testDifferentStringsProduceDifferentHashes() {
        XCTAssertNotEqual(stableHash("abc"), stableHash("abd"))
        XCTAssertNotEqual(stableHash("abc"), stableHash("ab"))
    }

    func testEmptyStringHashIsFNVOffsetBasis() {
        // FNV-1a 64-bit offset basis
        XCTAssertEqual(stableHash(""), 0xcbf29ce484222325)
    }

    func testPositionSensitive() {
        // "ab" + "c" should differ from "a" + "bc"
        XCTAssertNotEqual(stableHash("abc"), stableHash("acb"))
    }

    func testUnicodeStable() {
        let input = "模型: deepseek/deepseek-chat"
        XCTAssertEqual(stableHash(input), stableHash(input))
    }
}
