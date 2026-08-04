import XCTest
@testable import AIPulse

final class RepoScanCacheTests: XCTestCase {
    private var tempDir: URL!
    private var store: UserDefaults!
    private var cache: RepoScanCache!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoScanCacheTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = UserDefaults(suiteName: "RepoScanCacheTests-\(UUID().uuidString)")!
        cache = RepoScanCache(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        cache = nil
        store = nil
        super.tearDown()
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

    func testScanCollectsReposAndAiderMarkers() async {
        makeRepo("plain")
        makeRepo("aider-repo", aider: true)
        await cache.scan(dir: tempDir.path)

        let scan = cache.cachedScan(for: tempDir.path)
        XCTAssertNotNil(scan)
        XCTAssertEqual(scan?.repos.count, 2)
        XCTAssertEqual(scan?.repos.first { $0.name == "aider-repo" }?.hasAiderMarkers, true)
        XCTAssertEqual(scan?.repos.first { $0.name == "plain" }?.hasAiderMarkers, false)
        XCTAssertEqual(scan?.truncated, false)
    }

    func testPersistenceRoundTrip() async {
        makeRepo("persisted")
        await cache.scan(dir: tempDir.path)

        // 同一 store 上新建实例必须读到持久化的扫描结果。
        let cache2 = RepoScanCache(store: store)
        XCTAssertEqual(cache2.cachedScan(for: tempDir.path)?.repos.count, 1)
    }

    func testInvalidateRemovesEntry() async {
        makeRepo("gone")
        await cache.scan(dir: tempDir.path)
        XCTAssertNotNil(cache.cachedScan(for: tempDir.path))

        cache.invalidate(dir: tempDir.path)
        XCTAssertNil(cache.cachedScan(for: tempDir.path))
    }

    func testStaleScanTreatedAsMissing() {
        let stale = CachedDirScan(
            dirPath: tempDir.path,
            repos: [CachedRepo(path: tempDir.path + "/x", name: "x", hasAiderMarkers: false)],
            scannedAt: Date().addingTimeInterval(-(RepoScanCache.ttl + 60))
        )
        let data = try! JSONEncoder().encode([tempDir.path: stale])
        store.set(data, forKey: RepoScanCache.storeKey)

        let c = RepoScanCache(store: store)
        XCTAssertNil(c.cachedScan(for: tempDir.path))
    }
}
