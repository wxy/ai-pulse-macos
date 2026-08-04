import XCTest
@testable import AIPulse

final class AiderIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var cache: RepoScanCache!
    private let dirsKey = "repo_search_dirs"
    private var savedDirs: [String]?

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AiderIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        cache = RepoScanCache(store: UserDefaults(suiteName: "AiderIntegrationTests-\(UUID().uuidString)")!)
        savedDirs = UserDefaults.standard.stringArray(forKey: dirsKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        if let saved = savedDirs { UserDefaults.standard.set(saved, forKey: dirsKey) }
        else { UserDefaults.standard.removeObject(forKey: dirsKey) }
        cache = nil
    }

    private func makeRepo(_ rel: String, aider: Bool = false) {
        let r = tempDir.appendingPathComponent(rel)
        try! FileManager.default.createDirectory(
            at: r.appendingPathComponent(".git"), withIntermediateDirectories: true)
        if aider {
            FileManager.default.createFile(
                atPath: r.appendingPathComponent(".aider.chat.history.md").path, contents: Data())
        }
    }

    func testDetectsAiderFromCache() async {
        makeRepo("with-aider", aider: true)
        makeRepo("without")
        await cache.scan(dir: tempDir.path)
        UserDefaults.standard.set([tempDir.path], forKey: dirsKey)

        let result = AiderIntegration(cache: cache).detect()
        XCTAssertTrue(result.found)
    }

    func testNoMarkersNotDetected() async {
        makeRepo("without")
        await cache.scan(dir: tempDir.path)
        UserDefaults.standard.set([tempDir.path], forKey: dirsKey)

        let result = AiderIntegration(cache: cache).detect()
        XCTAssertFalse(result.found)
    }
}
