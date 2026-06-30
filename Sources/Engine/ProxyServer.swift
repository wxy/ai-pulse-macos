import Foundation
import Network

/// Lightweight HTTPS CONNECT proxy on 127.0.0.1.
/// Captures hostname + byte counts without decrypting TLS.
final class ProxyServer {
    static let shared = ProxyServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private(set) var isRunning = false

    /// Per-connection event: one CONNECT session.
    struct Event {
        let hostname: String    // e.g. "api.anthropic.com"
        let bytesSent: Int
        let bytesReceived: Int
        let timestamp: Date
    }

    /// Called on each completed CONNECT session.
    var onEvent: ((Event) -> Void)?

    // MARK: - Start / Stop

    func start(preferredPort: UInt16 = 18899) throws {
        guard !isRunning else { return }

        // Port detection
        port = PortDetector.findAvailable(startingFrom: preferredPort)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )

        listener = try NWListener(using: params)
        listener?.newConnectionHandler = handleConnection(_:)
        listener?.start(queue: .global(qos: .utility))
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))

        // Read CONNECT request line
        receiveConnectRequest(connection) { [weak self] hostname in
            guard let self, let hostname else {
                connection.cancel()
                return
            }

            // Establish target connection
            let targetHost = NWEndpoint.Host(hostname)
            guard let targetPort = NWEndpoint.Port(rawValue: 443) else {
                connection.cancel(); return
            }

            let targetConn = NWConnection(
                host: targetHost, port: targetPort, using: .tcp
            )
            targetConn.start(queue: .global(qos: .utility))

            // Send 200 to client after target connects
            targetConn.stateUpdateHandler = { state in
                if case .ready = state {
                    let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
                    connection.send(
                        content: response.data(using: .utf8),
                        completion: .contentProcessed { _ in }
                    )
                    // Start bidirectional tunneling
                    self.tunnel(client: connection, target: targetConn, hostname: hostname)
                }
                if case .failed = state {
                    connection.cancel()
                }
            }
        }
    }

    private func receiveConnectRequest(
        _ conn: NWConnection,
        completion: @escaping (String?) -> Void
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else {
                completion(nil); return
            }
            // Parse "CONNECT api.anthropic.com:443 HTTP/1.1"
            let lines = request.components(separatedBy: "\r\n")
            guard let firstLine = lines.first,
                  firstLine.hasPrefix("CONNECT ") else {
                completion(nil); return
            }
            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else { completion(nil); return }
            let hostPort = parts[1]
            let hostname = hostPort.components(separatedBy: ":").first ?? hostPort
            completion(hostname)
        }
    }

    private func tunnel(
        client: NWConnection,
        target: NWConnection,
        hostname: String
    ) {
        let counter = TunnelCounter()
        let group = DispatchGroup()

        // Client → Target
        group.enter()
        pipe(client, to: target, counter: counter, isUpload: true, group: group)

        // Target → Client
        group.enter()
        pipe(target, to: client, counter: counter, isUpload: false, group: group)

        group.notify(queue: .global(qos: .utility)) { [weak self] in
            self?.onEvent?(Event(
                hostname: hostname,
                bytesSent: counter.up,
                bytesReceived: counter.down,
                timestamp: Date()
            ))
        }
    }

    private func pipe(
        _ from: NWConnection, to: NWConnection,
        counter: TunnelCounter, isUpload: Bool, group: DispatchGroup
    ) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak from, weak to] data, _, isComplete, _ in
            guard let to else { group.leave(); return }

            if let data {
                if isUpload { counter.up += data.count }
                else { counter.down += data.count }
                to.send(content: data, completion: .contentProcessed { _ in })
            }

            if isComplete {
                to.cancel(); group.leave()
            } else if let from {
                self.pipe(from, to: to, counter: counter, isUpload: isUpload, group: group)
            } else {
                group.leave()
            }
        }
    }

    private final class TunnelCounter {
        var up: Int = 0
        var down: Int = 0
    }
}
