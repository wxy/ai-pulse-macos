import Foundation
import Network

/// Finds an available TCP port on 127.0.0.1.
enum PortDetector {
    /// Try to bind starting from `startingFrom`, incrementing up to 10 times.
    /// Falls back to a random port (port 0) if all attempts fail.
    static func findAvailable(startingFrom: UInt16 = 18899) -> UInt16 {
        for offset in 0..<10 {
            let port = startingFrom + UInt16(offset)
            if canBind(port: port) { return port }
        }
        // Random port
        return randomAvailable()
    }

    private static func canBind(port: UInt16) -> Bool {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        do {
            let listener = try NWListener(using: params)
            listener.cancel()
            return true
        } catch {
            return false
        }
    }

    private static func randomAvailable() -> UInt16 {
        // Try a range of high ports
        for port in UInt16(49152)...UInt16(49162) {
            if canBind(port: port) { return port }
        }
        return 18899
    }
}
