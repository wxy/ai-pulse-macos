import Foundation

/// Demo HTTP server on 127.0.0.1:8899 for the Chrome extension to read Mac stats.
/// Two endpoints:
///   GET /api/v1/health       → { version, integrations }
///   GET /api/v1/stats/today  → { cost, netLines, cpl }
final class LocalAPIServer {
    static let shared = LocalAPIServer()
    private var listener: FileHandle?
    private let port: UInt16 = 8899

    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.run() }
    }

    private func run() {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return }
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        guard bind(sock, withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, socklen_t(MemoryLayout<sockaddr_in>.size)) >= 0,
              listen(sock, 5) >= 0
        else { close(sock); return }

        print("Bridge API listening on 127.0.0.1:\(port)")

        while true {
            let client = accept(sock, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global(qos: .utility).async { self.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(client, &buf, buf.count, 0)
        guard n > 0, let req = String(bytes: buf[0..<n], encoding: .utf8) else { return }
        let firstLine = req.components(separatedBy: "\r\n").first ?? ""

        let (status, body) = response(for: firstLine)
        let http = """
        HTTP/1.1 \(status)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Access-Control-Allow-Origin: chrome-extension://*\r
        Connection: close\r
        \r
        \(body)
        """
        _ = http.withCString { send(client, $0, strlen($0), 0) }
    }

    private func response(for requestLine: String) -> (String, String) {
        if requestLine.hasPrefix("GET /api/v1/health") {
            let json = """
            {"ok":true,"version":"0.4.1","integrations":\(IntegrationRegistry.all.filter { $0.detect().found }.count)}
            """
            return ("200 OK", json)
        }
        if requestLine.hasPrefix("GET /api/v1/stats/today") {
            // Blocking call on background thread — fine for demo
            let sem = DispatchSemaphore(value: 0)
            var cost: Double = 0; var lines: Int = 0
            Task {
                let stats = await StatsService.dailyStats(days: 1)
                cost = stats.first?.cost ?? 0; lines = stats.first?.netLines ?? 0
                sem.signal()
            }
            sem.wait()
            let cpl = lines > 0 ? cost * 1000 / Double(lines) : 0
            let json = """
            {"cost":\(String(format:"%.4f",cost)),"netLines":\(lines),"cpl":\(String(format:"%.4f",cpl)),"cplUnit":"per 1000 lines"}
            """
            return ("200 OK", json)
        }
        return ("404 Not Found", "{\"error\":\"not found\"}")
    }
}
