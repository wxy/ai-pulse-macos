import XCTest
@testable import AIPulse

final class DiagnosticJournalTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticJournalTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func makeJournal(
        activeBytes: Int = 1024 * 1024,
        activeLines: Int = 2_000,
        archiveBytes: Int = 4 * 1024 * 1024
    ) -> DiagnosticJournal {
        DiagnosticJournal(
            directory: directory,
            activeByteLimit: activeBytes,
            activeLineLimit: activeLines,
            archiveByteLimit: archiveBytes
        )
    }

    private func activeLines() throws -> [[String: Any]] {
        let url = directory.appendingPathComponent("events-active.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(
                with: Data(line.utf8),
                options: [.fragmentsAllowed]
            )
            return try XCTUnwrap(object as? [String: Any])
        }
    }

    func testWritesVersionedJSONLine() throws {
        let journal = makeJournal()
        journal.log("test_event", [
            "range": .string("30d"),
            "count": .int(30),
            "ready": .bool(true),
        ])
        journal.flushForTesting()

        let lines = try activeLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["v"] as? Int, 1)
        XCTAssertEqual(lines.first?["seq"] as? Int, 1)
        XCTAssertEqual(lines.first?["event"] as? String, "test_event")
        XCTAssertNotNil(lines.first?["ts"] as? String)
        XCTAssertNotNil(lines.first?["session"] as? String)
        let data = try XCTUnwrap(lines.first?["data"] as? [String: Any])
        XCTAssertEqual(data["range"] as? String, "30d")
        XCTAssertEqual(data["count"] as? Int, 30)
        XCTAssertEqual(data["ready"] as? Bool, true)
    }

    func testNonFiniteDoublesBecomeNull() throws {
        let journal = makeJournal()
        journal.log("nonfinite", [
            "nan": .double(.nan),
            "infinity": .double(.infinity),
            "finite": .double(3.5),
        ])
        journal.flushForTesting()

        let lines = try activeLines()
        let data = try XCTUnwrap(lines.first?["data"] as? [String: Any])
        XCTAssertTrue(data["nan"] is NSNull)
        XCTAssertTrue(data["infinity"] is NSNull)
        XCTAssertEqual(data["finite"] as? Double, 3.5)
    }

    func testRotationCompressesOldActiveFile() throws {
        let journal = makeJournal(activeBytes: 256, activeLines: 3)
        for index in 0..<4 {
            journal.log("rotation", ["index": .int(index)])
        }
        journal.flushForTesting()

        XCTAssertEqual(try activeLines().count, 1)
        let archives = journal.archiveURLs()
        XCTAssertEqual(archives.count, 3)
        XCTAssertEqual(archives.first?.pathExtension, "zlib")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: archives.first!.path
        )
        XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 0)
    }

    func testArchiveBudgetDeletesOldest() throws {
        let journal = makeJournal(
            activeBytes: 128,
            activeLines: 2,
            archiveBytes: 1
        )
        for index in 0..<6 {
            journal.log("budget", ["index": .int(index)])
        }
        journal.flushForTesting()

        XCTAssertTrue(journal.archiveURLs().isEmpty)
        XCTAssertEqual(try activeLines().count, 1)
    }

    func testNestedValuesAreEncoded() throws {
        let journal = makeJournal()
        journal.log("nested", [
            "axes": .array([.double(1.5), .double(2.5)]),
            "detail": .object(["finite": .bool(true)]),
        ])
        journal.flushForTesting()

        let data = try XCTUnwrap(try activeLines().first?["data"] as? [String: Any])
        let axes = try XCTUnwrap(data["axes"] as? [Any])
        XCTAssertEqual(axes.count, 2)
        let detail = try XCTUnwrap(data["detail"] as? [String: Any])
        XCTAssertEqual(detail["finite"] as? Bool, true)
    }
}
