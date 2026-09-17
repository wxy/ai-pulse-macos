import Foundation

/// Display only: canonical Git roots remain the identity and lookup keys.
enum RepositoryLabels {
    static func make(for paths: [String]) -> [String: String] {
        let roots = Set(paths)
        var result: [String: String] = [:]
        for root in roots {
            let components = root.split(separator: "/").map(String.init)
            let name = components.last ?? root
            let peers = roots.filter { ($0.split(separator: "/").last.map(String.init) ?? $0) == name }
            guard peers.count > 1 else {
                result[root] = name
                continue
            }
            var depth = 2
            while depth < components.count {
                let suffix = components.suffix(depth).joined(separator: "/")
                if !peers.contains(where: { $0 != root && $0.split(separator: "/").suffix(depth).joined(separator: "/") == suffix }) {
                    break
                }
                depth += 1
            }
            // Keep the repository name first, so truncation retains its meaning.
            result[root] = "\(name) · \(components.dropLast().suffix(depth - 1).joined(separator: "/"))"
        }
        return result
    }
}
