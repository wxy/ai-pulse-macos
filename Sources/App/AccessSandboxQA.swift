#if DEBUG
import AppKit
import SwiftUI
import Combine
import GRDB

/// Explicit opt-in signed-sandbox acceptance runner. Only the dedicated bundle
/// can enter it. Uses production grant UI and I/O; no entitlement bypass,
/// account polling, CloudKit, production defaults, or production database.
@MainActor
final class AccessSandboxQA: ObservableObject {
    static var isEnabled: Bool { Bundle.main.bundleIdentifier == "xingyu.wang.aipulse.accessqa" }
    private static var instance: AccessSandboxQA?
    private var window: NSWindow?
    let home: URL
    let root: String
    private let watcher: LogWatcher
    @Published var result = "Scanning"

    static func start() {
        GitRepo.setup()
        guard let home = UserDefaults.standard.string(forKey: "AccessQAHome"),
              let root = UserDefaults.standard.string(forKey: "AccessQARoot") else {
            NSApp.terminate(nil); return
        }
        let runner = AccessSandboxQA(home: URL(fileURLWithPath: home), root: root)
        instance = runner
        runner.show()
    }

    init(home: URL, root: String) {
        self.home = home
        self.root = root
        UserDefaults.standard.set([root], forKey: "repo_search_dirs")
        if UserDefaults.standard.bool(forKey: "AccessQAInvalidBookmark") {
            var bookmarks = UserDefaults.standard.data(forKey: "security_scoped_bookmarks")
                .flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
            bookmarks[root] = Data([0, 1, 2])
            UserDefaults.standard.set(try? JSONEncoder().encode(bookmarks), forKey: "security_scoped_bookmarks")
        }
        _ = BookmarkManager.resolveAll()
        do { try AppDatabase.shared.setup() }
        catch { result = error.localizedDescription }
        watcher = LogWatcher(homeDirectory: home, database: .shared, repositoryRoots: [root])
    }

    func show() {
        let view = VStack(alignment: .leading, spacing: 12) {
            Text("Signed sandbox acceptance").font(.headline)
            Text(root).font(.caption)
            AccessSandboxQAResults(runner: self)
        }.padding(20).frame(width: 760, height: 540, alignment: .topLeading)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AI Pulse Access QA"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func refresh() {
        Task {
            await RepoScanCache.shared.scan(dir: root)
            await watcher.scanAndWait()
            let scan = RepoScanCache.shared.cachedScan(for: root)
            let count = (try? await AppDatabase.shared.read {
                try Int.fetchOne($0, sql: "SELECT count(*) FROM usage_event WHERE source = 'codex'") ?? 0
            }) ?? -1
            let tokenCount = (try? await AppDatabase.shared.read {
                try Int.fetchOne($0, sql: "SELECT sum(in_tokens + out_tokens) FROM usage_event WHERE source = 'codex'") ?? 0
            }) ?? -1
            var git = "none"
            if let path = scan?.repos.first?.path ?? UserDefaults.standard.string(forKey: "AccessQAGitRepo") {
                do { git = "\(try GitRepo(path: path).log(since: nil).commits.count) commits" }
                catch { git = error.localizedDescription }
            }
            result = "repos=\(scan?.usableCount.map(String.init) ?? "unavailable"); codexRows=\(count); tokens=\(tokenCount); git=\(git); issues=\(DirectoryAccess.shared.issues.count); ingestErrors=\(AppHealthMonitor.shared.failingIngestSources.count)"
            Logger.info("SANDBOX_QA \(result)")
        }
    }
}

@MainActor
private struct AccessSandboxQAResults: View {
    @ObservedObject var runner: AccessSandboxQA
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: runner.result).textSelection(.enabled).accessibilityIdentifier("access-qa-result")
            Button("Authorize fixture home") {
                guard BookmarkManager.requestAccess(defaultDirectory: runner.home.path) != nil else { return }
                runner.refresh()
            }
            Button("Scan") { runner.refresh() }
            ScrollView { DirectoryAccessGuidance(onGranted: { runner.refresh() }) }
        }
    }
}
#endif
